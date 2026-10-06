import Foundation

private struct JournalEntry: Codable {
    var version = 1
    let sequence: Int
    let at: Date
    let change: LessonChange
}

/// 事件先同步落盘，再更新快照；公开文档可从事件重建。
public actor LessonRepository {
    public let root: URL
    private var cache: [UUID: (lesson: Lesson, sequence: Int)] = [:]
    private var failedWrites = Set<UUID>()
    public private(set) var recoveryWarnings: [String] = []
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    public func create(title: String, source: String) throws -> Lesson {
        var lesson = Lesson(title: title, source: source)
        lesson.paragraphStyle = 2
        let folder = directory(lesson.id)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("audio"), withIntermediateDirectories: true)
        cache[lesson.id] = (lesson, 0)
        return try append(.created(lesson), to: lesson.id)
    }

    @discardableResult
    public func append(_ change: LessonChange, to id: UUID) throws -> Lesson {
        guard !failedWrites.contains(id) else { throw LessonError.api("此记录发生过写入错误，已停止追加；请重新打开应用进行恢复。") }
        if cache[id] == nil { _ = try load(id) }
        guard var current = cache[id] else { throw LessonError.missingLesson }
        let entry = JournalEntry(sequence: current.sequence + 1, at: Date(), change: change)
        var data = try encoder.encode(entry)
        data.append(0x0A)
        let url = directory(id).appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .withoutOverwriting) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            // 未确认落盘的记录禁止继续追加，避免把半条日志变成中间损坏。
            failedWrites.insert(id)
            throw error
        }
        LessonReducer.apply(change, to: &current.lesson)
        current.sequence += 1
        current.lesson.sequence = current.sequence
        cache[id] = current
        return current.lesson
    }

    public func load(_ id: UUID) throws -> Lesson {
        if let cached = cache[id] { return cached.lesson }
        let url = directory(id).appendingPathComponent("events.jsonl")
        let raw = try Data(contentsOf: url)
        // 仅允许隔离最后一条未写完整的尾部；中间损坏和未知版本不继续写入。
        let boundary = raw.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        let complete = raw.prefix(boundary)
        let rows = complete.split(separator: 0x0A)
        var value: Lesson?
        var seq = 0
        for row in rows {
            let entry = try decoder.decode(JournalEntry.self, from: Data(row))
            guard entry.version == 1, entry.sequence == seq + 1 else { throw LessonError.invalidLog }
            if value == nil {
                guard case .created(let initial) = entry.change, initial.id == id else { throw LessonError.invalidLog }
                value = initial
            }
            LessonReducer.apply(entry.change, to: &value!)
            seq = entry.sequence
            value?.sequence = seq
        }
        guard let lesson = value else { throw LessonError.invalidLog }
        if boundary < raw.count {
            try raw.suffix(from: boundary).write(to: directory(id).appendingPathComponent("incomplete-\(UUID().uuidString).bin"), options: .withoutOverwriting)
            try Data(complete).write(to: url, options: .atomic)
        }
        cache[id] = (lesson, seq)
        return lesson
    }

    public func list() throws -> [Lesson] {
        recoveryWarnings = []
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { url in
                guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
                do { return try load(id) }
                catch { recoveryWarnings.append("记录 \(id.uuidString) 无法读取，原始文件已保留：\(error.localizedDescription)"); return nil }
            }.sorted { $0.createdAt > $1.createdAt }
    }

    public func recover() throws -> [Lesson] {
        for lesson in try list() where [.preparing, .recording, .paused, .finishing].contains(lesson.phase) {
            try append(.issue("上次运行意外结束；音频目录可能包含尚未封口的文件，需核对末尾。"), to: lesson.id)
            try append(.phase(.interrupted, lesson.duration), to: lesson.id)
            try project(lesson.id)
        }
        return try list()
    }

    public func project(_ id: UUID) throws {
        let lesson = try load(id)
        let files = LessonText.files(for: lesson)
        for (name, text) in files {
            try Data(text.utf8).write(to: directory(id).appendingPathComponent(name), options: .atomic)
        }
        // 本机资料夹里的投影随记录重建：内容已清空或旧版文件名的投影直接移除（导出到课程文件夹的文件不受影响）。
        for name in LessonText.projectionNames where files[name] == nil {
            try? FileManager.default.removeItem(at: directory(id).appendingPathComponent(name))
        }
        try encoder.encode(lesson).write(to: directory(id).appendingPathComponent("session.json"), options: .atomic)
    }

    /// 导出到新子目录；从不覆盖用户已存在的文件，也不把内部日志导出。
    public func export(_ id: UUID, into parent: URL, includeAudio: Bool) throws -> URL {
        let lesson = try load(id)
        let safe = lesson.title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")).joined(separator: "-")
        let folder = parent.appendingPathComponent("\(String(safe.prefix(70))) - \(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            for (name, text) in LessonText.files(for: lesson) {
                try Data(text.utf8).write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
            }
            try encoder.encode(lesson).write(to: folder.appendingPathComponent("session.json"), options: .withoutOverwriting)
            if includeAudio {
                try FileManager.default.copyItem(at: directory(id).appendingPathComponent("audio"), to: folder.appendingPathComponent("audio"))
            }
            return folder
        } catch {
            // 保留部分导出并明确失败，不删除用户目录。
            throw LessonError.api("导出未完成，已写入的文件保留在 \(folder.path)：\(error.localizedDescription)")
        }
    }
}

import CryptoKit

/// 账本里一个文件的记录：课程文件夹里的实际文件名，与上次写入内容的哈希。
public struct LedgerRecord: Codable, Sendable, Equatable {
    public var path: String
    public var hash: String
    public init(path: String, hash: String) { self.path = path; self.hash = hash }
}

private struct ExportLedger: Codable {
    var files: [String: LedgerRecord] = [:]
    var sequence = 0
}

/// 交接前在资料库队列里取出的快照：渲染好的文件、已有的固定身份与账本。写盘在队列之外进行，不拖住正在录的课。
public struct HandoffSnapshot: Sendable {
    public var lesson: Lesson
    public var courseID: UUID
    /// 固定文件名（如“课堂转录.txt”）→ 内容。
    public var files: [String: Data]
    public var binding: ExportBinding?
    public var ledger: [String: LedgerRecord]
}

/// 一次写盘的结果，交回资料库登记。
public struct HandoffOutcome: Sendable, Equatable {
    public var prefix: String
    public var ledger: [String: LedgerRecord]
    public var files: [String]
    public var written: Int
    public var conflicts: [String]
    public var skipped: [String]
    /// 写到一半出错时的原因。此前已经写成功的文件仍在 `ledger` 里，必须一并登记，否则重试会把它们当成别人的文件。
    public var failure: String?
}

/// 把一堂课的文件写进课程文件夹。不依赖资料库状态，可在任何线程执行。
public enum HandoffWriter {
    /// 文件夹里属于“某个开头”的本 App 文件：固定文件名，或这堂课的录音。别人写的同开头文件（如外部 Agent 的整理稿）不算。
    static func owned(_ prefix: String, in names: [String]) -> [String] {
        let fixed = Set(LessonText.projectionNames.map { "\(prefix) \($0)" })
        return names.filter { fixed.contains($0) || ($0.hasPrefix("\(prefix) 录音 ") && $0.hasSuffix(".m4a")) }
    }

    /// 第一次交到这门课：定下文件名开头。撞上别的课堂的文件就加序号；是这堂课以前交出的就认领。
    /// `reserved`：这门课里其他课堂已经定下的开头。它们的文件可能已被归档走、文件夹里看不到，但仍然不能再用。
    static func resolve(_ base: String, snapshot: HandoffSnapshot, folder: URL, reserved: Set<String> = []) -> (prefix: String, ledger: [String: LedgerRecord]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let ownAudio = " 录音 \(snapshot.lesson.id.uuidString.prefix(8)).m4a"
        for index in 1...30 {
            let candidate = index == 1 ? base : "\(base) (\(index))"
            if reserved.contains(candidate) { continue }
            let taken = owned(candidate, in: names)
            if taken.isEmpty { return (candidate, [:]) }
            var ledger: [String: LedgerRecord] = [:]
            var identical = true
            for file in taken where !file.hasSuffix(".m4a") {
                let name = String(file.dropFirst(candidate.count + 1))
                guard let data = snapshot.files[name], let existing = try? Data(contentsOf: folder.appendingPathComponent(file)),
                      LessonRepository.digest(existing) == LessonRepository.digest(data) else { identical = false; continue }
                ledger[name] = LedgerRecord(path: file, hash: LessonRepository.digest(data))
            }
            // 录音文件名带这堂课的编号，或文字文件内容与现在要写的完全相同：就是这堂课以前交出的。
            let hasText = taken.contains { !$0.hasSuffix(".m4a") }
            if taken.contains("\(candidate)\(ownAudio)") || (identical && hasText) { return (candidate, ledger) }
        }
        return ("\(base) (LectoAI \(snapshot.lesson.id.uuidString.prefix(8)))", [:])
    }

    /// 文件被外部改过时，新内容另存的名字：原名 (LectoAI 更新 月日-时分).扩展名。
    static func conflictCopy(of url: URL, now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "MMdd-HHmm"
        let stamp = formatter.string(from: now)
        let folder = url.deletingLastPathComponent(), ext = url.pathExtension
        // 已经是副本的，不再叠一层后缀。
        let stem = url.deletingPathExtension().lastPathComponent.replacing(#/ \(LectoAI 更新 [^)]*\)$/#, with: "")
        var candidate = folder.appendingPathComponent("\(stem) (LectoAI 更新 \(stamp)).\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) (LectoAI 更新 \(stamp)-\(index)).\(ext)"); index += 1
        }
        return candidate
    }

    /// `manual` 为用户在导出面板里主动导出：被移走的文件会重新生成；自动更新则跳过它们。
    /// 不抛错：写到一半失败时返回已完成的部分与 `failure`，调用方照常登记，重试才是幂等的。
    public static func write(_ snapshot: HandoffSnapshot, into folder: URL, basePrefix: String, manual: Bool, reserved: Set<String> = [],
                             now: Date = Date()) -> HandoffOutcome {
        var ledger = snapshot.ledger
        let prefix: String
        if let binding = snapshot.binding { prefix = binding.prefix }
        else {
            let resolved = resolve(basePrefix, snapshot: snapshot, folder: folder, reserved: reserved)
            prefix = resolved.prefix; ledger = resolved.ledger
        }
        var written = 0
        var conflicts: [String] = [], skipped: [String] = [], files: [String] = []
        for (name, data) in snapshot.files.sorted(by: { $0.key < $1.key }) {
            let digest = LessonRepository.digest(data)
            let old = ledger[name]
            var destination = folder.appendingPathComponent(old?.path ?? "\(prefix) \(name)")
            var coordinationError: NSError?
            var writingError: Error?
            var skip = false
            // 协作访问减少与支持文件协调的编辑器产生竞争；写入前再次核对内容。
            NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { coordinated in
                do {
                    if FileManager.default.fileExists(atPath: coordinated.path) {
                        let current = LessonRepository.digest(try Data(contentsOf: coordinated, options: .mappedIfSafe))
                        if current == digest { return }
                        // 文件被外部改过，而我们这边的内容自上次写入后没有变：不动它，也不另存。
                        if let old, digest == old.hash { return }
                        if let old, current == old.hash {
                            try data.write(to: coordinated, options: .atomic); written += 1
                        } else {
                            // 被外部改过（或来历不明）：保留它，新内容另存一份。
                            destination = conflictCopy(of: destination, now: now)
                            try data.write(to: destination, options: .withoutOverwriting)
                            conflicts.append(destination.lastPathComponent); written += 1
                        }
                    } else if old != nil, !manual {
                        skip = true
                    } else {
                        try data.write(to: coordinated, options: .withoutOverwriting); written += 1
                    }
                } catch { writingError = error }
            }
            if let error = coordinationError ?? writingError as NSError? {
                return HandoffOutcome(prefix: prefix, ledger: ledger, files: files, written: written, conflicts: conflicts, skipped: skipped,
                                      failure: error.localizedDescription)
            }
            if skip { skipped.append(name); continue }
            // 外部改过而我们没有新内容时保留原来的账本记录，下次有新内容仍能认出它被改过。
            if let old, digest == old.hash { ledger[name] = old } else { ledger[name] = LedgerRecord(path: destination.lastPathComponent, hash: digest) }
            files.append(ledger[name]?.path ?? destination.lastPathComponent)
        }
        return HandoffOutcome(prefix: prefix, ledger: ledger, files: files, written: written, conflicts: conflicts, skipped: skipped, failure: nil)
    }

    /// 冲突副本对应的原文件名（去掉“(LectoAI 更新 …)”），用于在 Finder 里把两者一起选中。
    public static func original(ofCopy name: String) -> String {
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent.replacing(#/ \(LectoAI 更新 [^)]*\)$/#, with: "")
        return url.pathExtension.isEmpty ? stem : "\(stem).\(url.pathExtension)"
    }
}

extension LessonRepository {
    /// 哈希账本只留在本机。已有外部改动保留，冲突时生成新的候选文件。
    /// `name` 为导出时手动输入的文件名开头（为空则按命名模板）；`only` 只导出其中的文件（nil 为全部）。
    public func exportManaged(_ id: UUID, into parent: URL, naming: ExportNaming, name custom: String? = nil, only: Set<String>? = nil) throws -> URL {
        let lesson = try load(id)
        let prefix = try custom.map(ExportNaming.clean) ?? naming.prefix(for: lesson)
        let identity = parent.standardizedFileURL.path + "|" + prefix
        let ledgerURL = directory(id).appendingPathComponent("export-\(Self.digest(Data(identity.utf8))).json")
        var ledger: ExportLedger
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            ledger = try decoder.decode(ExportLedger.self, from: Data(contentsOf: ledgerURL))
        } else { ledger = ExportLedger() }
        guard lesson.sequence >= ledger.sequence else { return parent }
        for (name, text) in LessonText.files(for: lesson).sorted(by: { $0.key < $1.key }) where only?.contains(name) ?? true {
            let data = Data(text.utf8)
            let digest = Self.digest(data)
            let old = ledger.files[name]
            var destination = parent.appendingPathComponent(old?.path ?? "\(prefix) \(name)")
            var coordinationError: NSError?
            var writingError: Error?
            // 协作访问减少与支持文件协调的编辑器产生竞争；写入前再次核对内容。
            NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { coordinated in
                do {
                    if FileManager.default.fileExists(atPath: coordinated.path) {
                        let current = try Data(contentsOf: coordinated, options: .mappedIfSafe)
                        let currentHash = Self.digest(current)
                        if currentHash == digest, old != nil { return }
                        if let old, currentHash == old.hash {
                            try data.write(to: coordinated, options: .atomic)
                        } else {
                            destination = HandoffWriter.conflictCopy(of: destination, now: Date())
                            try data.write(to: destination, options: .withoutOverwriting)
                        }
                    } else { try data.write(to: coordinated, options: .withoutOverwriting) }
                } catch { writingError = error }
            }
            if let error = coordinationError ?? writingError as NSError? { throw error }
            ledger.files[name] = .init(path: destination.lastPathComponent, hash: digest)
            ledger.sequence = lesson.sequence
            // 每个文件成功后保存账本，部分失败后的重试沿用已经写入的路径。
            try encoder.encode(ledger).write(to: ledgerURL, options: .atomic)
        }
        return parent
    }

    public func missingAudioFiles(_ id: UUID) throws -> [String] {
        let lesson = try load(id)
        return lesson.audio.filter { !FileManager.default.fileExists(atPath: directory(id).appendingPathComponent("audio/\($0.file)").path) }.map(\.file)
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // MARK: 交到课程文件夹（C1）

    private func ledgerURL(_ id: UUID, identity: String) -> URL {
        directory(id).appendingPathComponent("export-\(Self.digest(Data(identity.utf8))).json")
    }

    /// 账本按“课程 + 文件名开头”识别，不含路径：课程文件夹移动或改名后仍是同一份。
    private static func courseIdentity(_ courseID: UUID, _ prefix: String) -> String { "course:\(courseID.uuidString)|\(prefix)" }

    /// 交接第一步（队列内）：渲染文件，取出这门课的固定身份与账本。
    public func handoffSnapshot(_ id: UUID, courseID: UUID, only: Set<String>? = nil) throws -> HandoffSnapshot {
        let lesson = try load(id)
        var files: [String: Data] = [:]
        for (name, text) in LessonText.files(for: lesson) where only?.contains(name) ?? true { files[name] = Data(text.utf8) }
        let binding = lesson.bindings?.first { $0.courseID == courseID }
        var ledger: [String: LedgerRecord] = [:]
        if let binding, let data = try? Data(contentsOf: ledgerURL(id, identity: Self.courseIdentity(courseID, binding.prefix))),
           let value = try? decoder.decode(ExportLedger.self, from: data) { ledger = value.files }
        return HandoffSnapshot(lesson: lesson, courseID: courseID, files: files, binding: binding, ledger: ledger)
    }

    /// 交接第三步（队列内）：第一次交接时登记固定身份，保存账本，并在结果值得记录时追加一条交接记录。
    @discardableResult
    public func recordHandoff(_ snapshot: HandoffSnapshot, outcome: HandoffOutcome, folderName: String, timeZoneID: String, audio: String? = nil) throws -> Lesson {
        let id = snapshot.lesson.id
        if snapshot.binding == nil {
            try append(.bound(ExportBinding(courseID: snapshot.courseID, prefix: outcome.prefix, timeZoneID: timeZoneID)), to: id)
        }
        let url = ledgerURL(id, identity: Self.courseIdentity(snapshot.courseID, outcome.prefix))
        try encoder.encode(ExportLedger(files: outcome.ledger, sequence: snapshot.lesson.sequence)).write(to: url, options: .atomic)
        // 写到一半失败：已写的部分上面已经登记，这里记下失败原因。
        if let failure = outcome.failure {
            return try recordHandoffFailure(id, courseID: snapshot.courseID, folderName: folderName, prefix: outcome.prefix, error: failure)
        }
        let current = try load(id)
        let previous = current.receipts?.last { $0.courseID == snapshot.courseID }
        // 还没被用户看过的冲突副本延续到后面的记录里，不会被下一次普通更新冲掉。
        let conflicts = outcome.conflicts + (previous?.error == nil ? previous?.conflicts ?? [] : []).filter { !outcome.conflicts.contains($0) }
        // 内容没有变化、结果与上次相同时不追加记录，日志不随每次触发增长。
        let notable = outcome.written > 0 || previous == nil || previous?.error != nil || previous?.skipped != outcome.skipped
            || (audio != nil && previous?.audio != audio)
        guard notable else { return current }
        let receipt = ExportReceipt(courseID: snapshot.courseID, folderName: folderName, prefix: outcome.prefix, files: outcome.files,
                                    written: outcome.written, conflicts: conflicts, skipped: outcome.skipped, audio: audio ?? previous?.audio)
        return try append(.exported(receipt), to: id)
    }

    /// 录音单独登记：文字写完就已经记过一条，录音合成慢、也可能失败，不能拖着文字的登记。
    @discardableResult
    public func recordHandoffAudio(_ id: UUID, courseID: UUID, audio: String) throws -> Lesson {
        let current = try load(id)
        guard var receipt = current.receipts?.last(where: { $0.courseID == courseID && $0.error == nil }), receipt.audio != audio else { return current }
        receipt.id = UUID(); receipt.at = Date(); receipt.audio = audio; receipt.written = 0
        return try append(.exported(receipt), to: id)
    }

    /// 用户看过冲突副本之后：记一条不带冲突的交接记录，状态回到“已交到”。
    @discardableResult
    public func acknowledgeConflicts(_ id: UUID, courseID: UUID) throws -> Lesson {
        let current = try load(id)
        guard var receipt = current.receipts?.last(where: { $0.courseID == courseID }), receipt.error == nil, !receipt.conflicts.isEmpty else { return current }
        receipt.id = UUID(); receipt.conflicts = []; receipt.written = 0
        return try append(.exported(receipt), to: id)
    }

    /// 交接失败：记下原因。同一原因的连续失败只记一条。
    @discardableResult
    public func recordHandoffFailure(_ id: UUID, courseID: UUID, folderName: String, prefix: String, error: String) throws -> Lesson {
        let current = try load(id)
        if let previous = current.receipts?.last(where: { $0.courseID == courseID }), previous.error == error { return current }
        return try append(.exported(ExportReceipt(courseID: courseID, folderName: folderName, prefix: prefix, error: error)), to: id)
    }

    /// 升级前交到过这个文件夹的课堂：按当初的账本补上固定身份，不读课程文件夹里的内容。
    /// 旧账本的文件名是“路径|开头”的哈希，反推不出开头；但账本里记着实际文件名（“开头 课堂转录.txt”），
    /// 由它得到开头，再用哈希校验这份账本确实属于这个文件夹。同一堂课有多份（改过标题或模板）时取最近写过的那份。
    public func adoptLegacyExport(_ id: UUID, folderPath: String, courseID: UUID, timeZoneID: String) throws -> Lesson? {
        let lesson = try load(id)
        guard lesson.bindings?.contains(where: { $0.courseID == courseID }) != true else { return nil }
        let folder = directory(id)
        let ledgers = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("export-") && $0.pathExtension == "json" }
        var best: (prefix: String, url: URL, date: Date)?
        for url in ledgers {
            guard let data = try? Data(contentsOf: url), let ledger = try? decoder.decode(ExportLedger.self, from: data) else { continue }
            // 冲突副本的名字不以固定文件名结尾，跳过它们，用其余任意一条反推。
            guard let prefix = ledger.files.compactMap({ name, record -> String? in
                record.path.hasSuffix(" " + name) ? String(record.path.dropLast(name.count + 1)) : nil
            }).first, ledgerURL(id, identity: folderPath + "|" + prefix).lastPathComponent == url.lastPathComponent else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if best == nil || date > best!.date { best = (prefix, url, date) }
        }
        guard let best else { return nil }
        let target = ledgerURL(id, identity: Self.courseIdentity(courseID, best.prefix))
        if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: best.url, to: target) }
        return try append(.bound(ExportBinding(courseID: courseID, prefix: best.prefix, timeZoneID: timeZoneID)), to: id)
    }
}
