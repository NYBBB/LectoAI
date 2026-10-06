import Foundation
import CryptoKit
import Observation

struct ModelAssetManifest: Decodable, Sendable {
    struct File: Decodable, Sendable { let path: String; let url: URL; let size: Int64; let hash: String; let algorithm: String }
    let id: String
    let files: [File]
}

/// 固定仓库版本和每个文件的摘要；只把完整校验过的目录发布为可用模型。
actor WhisperAssets {
    static let shared = WhisperAssets()
    private var installing = false
    private func manifest() throws -> ModelAssetManifest {
        guard let url = Bundle.main.url(forResource: "WhisperManifest", withExtension: "json") else { throw CaptureFailure("缺少模型清单。") }
        return try JSONDecoder().decode(ModelAssetManifest.self, from: Data(contentsOf: url))
    }
    private func root() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LectoAI/Models", isDirectory: true)
    }
    func installed() throws -> URL? {
        let info = try manifest(), folder = try root().appendingPathComponent(info.id)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready.json").path) else { return nil }
        for file in info.files {
            let values = try folder.appendingPathComponent(file.path).resourceValues(forKeys: [.fileSizeKey])
            guard Int64(values.fileSize ?? -1) == file.size else { return nil }
        }
        return folder
    }
    func validate(_ folder: URL) throws {
        for file in try manifest().files {
            guard try verified(folder.appendingPathComponent(file.path), file: file) else { throw CaptureFailure("模型校验失败，请重新准备资源：\(file.path)") }
        }
    }
    func install(progress: @Sendable (Double) async -> Void) async throws -> URL {
        guard !installing else { throw CaptureFailure("模型已在下载。") }
        installing = true
        defer { installing = false }
        let info = try manifest(), base = try root(), target = base.appendingPathComponent(info.id)
        if let existing = try installed(), (try? validate(existing)) != nil { return existing }
        let staging = base.appendingPathComponent(info.id + ".partial")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let available = try base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard available > 1_300_000_000 else { throw CaptureFailure("请至少预留 1.3 GB 空间下载并校验后备模型。") }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let total = Double(info.files.reduce(Int64(0)) { $0 + $1.size })
        var completed = 0.0
        for file in info.files {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(file.path)
            if (try? verified(destination, file: file)) != true {
                let (temp, response) = try await download(file.url, session: session)
                defer { try? FileManager.default.removeItem(at: temp) }
                guard (response as? HTTPURLResponse)?.statusCode == 200, try verified(temp, file: file) else { throw CaptureFailure("模型下载未通过校验，请重试。已校验文件会保留。") }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: temp, to: destination)
            }
            completed += Double(file.size)
            await progress(completed / total)
        }
        try Data(info.id.utf8).write(to: staging.appendingPathComponent("ready.json"), options: .atomic)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.moveItem(at: target, to: base.appendingPathComponent("\(info.id).invalid-\(UUID())"))
        }
        try FileManager.default.moveItem(at: staging, to: target)
        return target
    }
    private func download(_ url: URL, session: URLSession) async throws -> (URL, URLResponse) {
        for attempt in 0..<3 {
            do {
                try Task.checkCancellation()
                let result = try await session.download(from: url)
                if let response = result.1 as? HTTPURLResponse, response.statusCode == 429 || response.statusCode >= 500 {
                    try? FileManager.default.removeItem(at: result.0)
                    throw CaptureFailure("模型服务暂不可用（\(response.statusCode)）。")
                }
                return result
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if attempt == 2 { throw error }
                try await Task.sleep(for: .seconds(Double(1 << attempt)))
            }
        }
        throw CaptureFailure("模型下载失败。")
    }
    func remove() throws {
        guard !installing else { throw CaptureFailure("下载中不能移除模型。") }
        let folder = try root().appendingPathComponent(manifest().id)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    private func verified(_ url: URL, file: ModelAssetManifest.File) throws -> Bool {
        guard Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1) == file.size else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha256 = SHA256(), sha1 = Insecure.SHA1()
        if file.algorithm == "git-sha1" { sha1.update(data: Data("blob \(file.size)\0".utf8)) }
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            if file.algorithm == "sha256" { sha256.update(data: data) } else { sha1.update(data: data) }
        }
        let result = file.algorithm == "sha256" ? sha256.finalize().map { String(format: "%02x", $0) }.joined() : sha1.finalize().map { String(format: "%02x", $0) }.joined()
        return result == file.hash
    }
}

@MainActor @Observable
final class WhisperResourceState {
    var ready = false
    var downloading = false
    var progress = 0.0
    var status = "后备模型可按需下载（约 630 MB）"
    private var task: Task<Void, Never>?
    func refresh() async {
        ready = (try? await WhisperAssets.shared.installed()) != nil
        if ready { status = "后备模型已准备" }
    }
    func download() {
        guard !downloading else { return }
        downloading = true; status = "正在准备后备模型…"
        let receiver = self
        task = Task {
            defer { downloading = false; task = nil }
            do {
                _ = try await WhisperAssets.shared.install { value in await receiver.report(value) }
                await refresh()
            } catch is CancellationError { status = "下载已取消；已校验的文件可在重试时复用。" }
            catch { status = error.localizedDescription }
        }
    }
    private func report(_ value: Double) { progress = value }
    func remove() {
        Task {
            do { try await WhisperAssets.shared.remove(); ready = false; status = "后备模型已移除，需要时可以重新下载。" }
            catch { status = error.localizedDescription }
        }
    }
    func cancel() { task?.cancel() }
}
