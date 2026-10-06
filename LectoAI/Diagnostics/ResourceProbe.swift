import Foundation
import Observation
import Speech
import Translation

@MainActor @Observable
final class ResourceProbe {
    private(set) var speech = "尚未检查"
    private(set) var translation = "尚未检查"
    private(set) var checking = false
    /// 至少完成过一次检查；之前不把“未知”误报为“不可用”。
    private(set) var checkedOnce = false
    private(set) var downloading = false
    private(set) var speechCanDownload = false
    private(set) var speechInstalled = false
    private(set) var translationInstalled = false
    private(set) var translationSupported = false
    private(set) var downloadProgress: Progress?
    private var downloadTask: Task<Void, Never>?

    /// 检查不申请麦克风权限，也不使用旧版 SFSpeechRecognizer 授权作为门槛。
    func refresh() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        if let transcriber = await makeTranscriber() {
            let status = await AssetInventory.status(forModules: [transcriber])
            speechInstalled = status == .installed
            speechCanDownload = status == .supported || status == .downloading
            switch status {
            case .installed: speech = "英语识别资源已安装"
            case .supported: speech = "需要下载英语识别资源"
            case .downloading: speech = "系统正在下载英语识别资源"
            case .unsupported: speech = "本机不支持此识别资源，可准备本地后备模型"
            @unknown default: speech = "未知资源状态"
            }
        } else {
            speech = "本机暂不支持 Apple 英语识别，可准备本地后备模型"
            speechCanDownload = false
            speechInstalled = false
        }
        let status = await LanguageAvailability().status(from: .init(identifier: "en"), to: .init(identifier: "zh-Hans"))
        translationInstalled = status == .installed
        translationSupported = status != .unsupported
        switch status {
        case .installed: translation = "英译中资源已安装"
        case .supported: translation = "英译中可用，需要准备语言资源"
        case .unsupported: translation = "本机暂不支持此翻译语言对"
        @unknown default: translation = "未知翻译状态"
        }
        checkedOnce = true
    }

    func downloadSpeech() {
        guard !downloading, speechCanDownload else { return }
        downloading = true
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { downloading = false; downloadProgress = nil; downloadTask = nil }
            do {
                guard let transcriber = await makeTranscriber() else { return }
                try Task.checkCancellation()
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    downloadProgress = request.progress
                    speech = "正在下载英语识别资源…"
                    try await request.downloadAndInstall()
                }
                try Task.checkCancellation()
                await refresh()
            } catch is CancellationError {
                speech = "已取消本次下载等待；系统资源状态可重新检查"
            } catch {
                speech = "识别资源准备失败：\(error.localizedDescription)"
            }
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

    private func makeTranscriber() async -> SpeechTranscriber? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { return nil }
        return SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
    }
}
