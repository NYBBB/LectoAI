import Foundation

public enum LessonPhase: String, Codable, Sendable { case preparing, recording, paused, finishing, completed, interrupted }

public struct TranscriptLine: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var original: String
    public var translation: String?
    public var revision: Int = 1
    public var repairID: UUID?
    public var engine: String?
    public var flags: [String]?
    public var runID: UUID
    public init(id: UUID = UUID(), start: Double, end: Double, original: String, runID: UUID) {
        self.id = id; self.start = start; self.end = end; self.original = original; self.runID = runID
    }
}

public struct LessonNote: Identifiable, Codable, Sendable, Equatable {
    public var id = UUID()
    public var createdAt = Date()
    public var segmentID: UUID?
    public var mediaTime: Double?
    public var recordedMediaTime: Double?
    public var quote: String?
    public var translatedQuote: String?
    public var text: String
    public var deleted = false
    /// 快捷标记类型（见 NoteMark）；普通笔记为 nil。旧记录没有此字段。
    public var kind: String?
    public init(line: TranscriptLine?, mediaTime: Double?, text: String = "") {
        recordedMediaTime = mediaTime
        segmentID = line?.id; self.mediaTime = line?.start ?? mediaTime
        quote = line?.original; translatedQuote = line?.translation; self.text = text
    }
}

public struct LessonAnswer: Identifiable, Codable, Sendable, Equatable {
    public var id = UUID()
    public var question: String
    public var answer: String
    public var citations: [UUID]
    /// 提问时的课堂时间，用于把问答放进纪要时间线；旧记录与课后提问为 nil。
    public var mediaTime: Double?
    public init(question: String, answer: String, citations: [UUID], mediaTime: Double? = nil) {
        self.question = question; self.answer = answer; self.citations = citations; self.mediaTime = mediaTime
    }
}

public struct AudioChunk: Codable, Sendable, Equatable {
    public var file: String
    public var start: Double
    public var duration: Double
    public init(file: String, start: Double, duration: Double) {
        self.file = file; self.start = start; self.duration = duration
    }
}

/// 这堂课归到哪门课，以及凭什么归的。
public struct Filing: Codable, Sendable, Equatable {
    /// nil 表示用户明确选择不归档。
    public var courseID: UUID?
    /// 课程名快照：课程被删除后仍能显示。
    public var courseName: String
    /// known（按以往上课时间）/ manual（手动选的）/ confirmed（确认了建议）/ asked（下课时选的）/ created（新建课程时）/ migrated（升级时认领）/ declined（不归档）。
    public var basis: String
    public var at: Date
    public init(courseID: UUID?, courseName: String, basis: String, at: Date = Date()) {
        self.courseID = courseID; self.courseName = courseName; self.basis = basis; self.at = at
    }
}

/// 交接的固定身份：第一次交到某门课时定下文件名开头与时区，之后的更新一直沿用。
public struct ExportBinding: Codable, Sendable, Equatable {
    public var courseID: UUID
    public var prefix: String
    public var timeZoneID: String
    public init(courseID: UUID, prefix: String, timeZoneID: String) {
        self.courseID = courseID; self.prefix = prefix; self.timeZoneID = timeZoneID
    }
}

/// 一次交接的结果。失败时 `error` 不为空，其余列表为空。
public struct ExportReceipt: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var at: Date
    public var courseID: UUID
    public var folderName: String
    public var prefix: String
    /// 课程文件夹里属于这堂课的文件（实际文件名）。
    public var files: [String]
    /// 这次真正写入的文件数；0 表示内容没有变化。
    public var written: Int
    /// 文件被外部改过、新内容另存成的副本名。
    public var conflicts: [String]
    /// 上次交出、现在已被移走的文件；自动更新不再放回。
    public var skipped: [String]
    public var audio: String?
    public var error: String?
    public init(at: Date = Date(), courseID: UUID, folderName: String, prefix: String, files: [String] = [], written: Int = 0,
                conflicts: [String] = [], skipped: [String] = [], audio: String? = nil, error: String? = nil) {
        self.at = at; self.courseID = courseID; self.folderName = folderName; self.prefix = prefix; self.files = files
        self.written = written; self.conflicts = conflicts; self.skipped = skipped; self.audio = audio; self.error = error
    }
}

/// 一堂课的交接状态，由归课与交接记录推出。
public enum HandoffStatus: Equatable, Sendable {
    /// 还没归到任何课程。
    case unfiled
    /// 用户明确选择不归档。
    case declined
    /// 归了课，还没交过。
    case waiting(course: String)
    case delivered(course: String, at: Date, files: Int)
    /// 已交，但有文件被外部改过，新内容另存了副本。
    case conflicted(course: String, at: Date, copies: [String])
    case failed(course: String, reason: String)
}

public struct Lesson: Identifiable, Codable, Sendable, Equatable {
    /// 创建时的系统时区；没归课的课堂命名用它。旧记录没有。
    public var timeZoneID: String?
    /// 上课日期的覆盖值：导入的录音取录制时间。旧记录没有。
    public var recordedAt: Date?
    /// 归课、固定身份与交接记录（C1）。旧记录没有。
    public var filing: Filing?
    public var bindings: [ExportBinding]?
    public var receipts: [ExportReceipt]?
    public var gaps: [RecognitionGap]?
    public var paragraphTranslations: [ParagraphTranslation]?
    public var structuredInsight: ClassroomInsight?
    /// 课堂纪要（按话题分节）与“此刻”，由 AI 整理；旧记录没有这些字段。
    public var digest: [DigestSection]?
    public var focus: LiveFocus?
    /// 主窗口“总结”页的连续文章（U9）；旧记录没有。
    public var article: [ArticleParagraph]?
    public var studyDrafts: [StudyDraft]?
    public var aiRequests: Int?
    /// 段落规则版本：nil/1 为旧规则（8 句/90 秒），2 为短段落（4 句/45 秒）。
    public var paragraphStyle: Int?
    /// 每次 AI 调用的记录（O1）；旧记录没有。
    public var aiCalls: [AICall]?
    public var sequence: Int = 0
    public var id: UUID
    public var createdAt: Date
    public var title: String
    public var source: String
    public var phase: LessonPhase = .preparing
    public var duration: Double = 0
    public var lines: [TranscriptLine] = []
    public var notes: [LessonNote] = []
    public var answers: [LessonAnswer] = []
    public var topic: String = ""
    public var keyPoints: String = ""
    public var audio: [AudioChunk] = []
    public var issues: [String] = []
    public init(id: UUID = UUID(), title: String, source: String) {
        self.id = id; self.createdAt = Date(); self.title = title; self.source = source
        timeZoneID = TimeZone.current.identifier
    }

    /// 导入录音的课堂，`source` 是这个值；它没有真实的上课时刻，不用来认课。
    public static let importedSource = "文件导入"

    /// 上课日期：导入的录音用录制时间，其余用创建时间。
    public var classDate: Date { recordedAt ?? createdAt }

    /// 当前归属课程的固定身份。改归到别的课再改回来时，仍能找到原来的那一份。
    public var binding: ExportBinding? {
        guard let id = filing?.courseID else { return nil }
        return bindings?.first { $0.courseID == id }
    }

    /// 当前归属课程的最近一次交接记录。
    public var lastReceipt: ExportReceipt? {
        guard let id = filing?.courseID else { return nil }
        return receipts?.last { $0.courseID == id }
    }

    public var handoffStatus: HandoffStatus {
        guard let filing else { return .unfiled }
        guard filing.courseID != nil else { return .declined }
        guard let receipt = lastReceipt else { return .waiting(course: filing.courseName) }
        if let error = receipt.error { return .failed(course: filing.courseName, reason: error) }
        if !receipt.conflicts.isEmpty { return .conflicted(course: filing.courseName, at: receipt.at, copies: receipt.conflicts) }
        return .delivered(course: filing.courseName, at: receipt.at, files: receipt.files.count)
    }
}

public enum LessonChange: Codable, Sendable {
    case created(Lesson)
    case phase(LessonPhase, Double)
    case line(TranscriptLine)
    case translation(UUID, Int, String)
    case note(LessonNote)
    case answer(LessonAnswer)
    case insight(String, String)
    case chunk(AudioChunk)
    case issue(String)
    case title(String)
    case aiRequest
    case repairFinished(RecognitionGap, [TranscriptLine])
    case gap(RecognitionGap)
    case paragraph(ParagraphTranslation)
    case structuredInsight(ClassroomInsight)
    case studyDraft(StudyDraft)
    case digestSection(DigestSection)
    case focus(LiveFocus)
    case aiCall(AICall)
    case articleParagraph(ArticleParagraph)
    /// 归课、固定身份、交接结果、上课日期覆盖（C1）。0.4.x 及更早版本不认识这些事件。
    case filed(Filing)
    case bound(ExportBinding)
    case exported(ExportReceipt)
    case recordedAt(Date)
}

public enum LessonError: LocalizedError {
    case invalidLog, missingLesson, invalidEndpoint, api(String)
    public var errorDescription: String? {
        switch self {
        case .invalidLog: "记录格式不完整或版本不支持。原始文件已保留。"
        case .missingLesson: "找不到课堂记录。"
        case .invalidEndpoint: "请输入 HTTPS API 地址（本机服务可使用 HTTP）和模型名称。"
        case .api(let message): message
        }
    }
}

public enum LessonReducer {
    public static func apply(_ change: LessonChange, to lesson: inout Lesson) {
        switch change {
        case .created(let value): lesson = value
        case .phase(let phase, let time): lesson.phase = phase; lesson.duration = max(lesson.duration, time)
        case .line(let line):
            if let index = lesson.lines.firstIndex(where: { $0.id == line.id }) {
                if line.revision > lesson.lines[index].revision { lesson.lines[index] = line }
            } else { lesson.lines.append(line) }
            lesson.lines.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        case .translation(let id, let revision, let text):
            if let index = lesson.lines.firstIndex(where: { $0.id == id && $0.revision == revision }) { lesson.lines[index].translation = text }
        case .note(let note):
            if let index = lesson.notes.firstIndex(where: { $0.id == note.id }) { lesson.notes[index] = note }
            else { lesson.notes.append(note) }
        case .answer(let answer):
            if !lesson.answers.contains(where: { $0.id == answer.id }) { lesson.answers.append(answer) }
        case .insight(let topic, let points): lesson.topic = topic; lesson.keyPoints = points
        case .chunk(let chunk):
            if !lesson.audio.contains(where: { $0.file == chunk.file }) { lesson.audio.append(chunk) }
            lesson.audio.sort { $0.start < $1.start }
            lesson.duration = max(lesson.duration, chunk.start + chunk.duration)
        case .issue(let issue): lesson.issues.append(issue)
        case .title(let title): lesson.title = title
        case .repairFinished(let gap, let replacement):
            let previous = lesson.lines.filter { $0.repairID == gap.id }
            lesson.lines.removeAll { $0.repairID == gap.id }
            lesson.lines.append(contentsOf: replacement)
            lesson.lines.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
            // 重放整个任务作为一个事件提交，重试替换同任务结果，引用快照原样保留。
            for index in lesson.notes.indices {
                if let old = previous.first(where: { $0.id == lesson.notes[index].segmentID }),
                   let new = replacement.min(by: { abs($0.start - old.start) < abs($1.start - old.start) }) {
                    lesson.notes[index].segmentID = new.id
                }
            }
            var gaps = lesson.gaps ?? []
            if let index = gaps.firstIndex(where: { $0.id == gap.id }) { gaps[index] = gap } else { gaps.append(gap) }
            lesson.gaps = gaps
        case .gap(let gap):
            var gaps = lesson.gaps ?? []
            if let i = gaps.firstIndex(where: { $0.id == gap.id }) { gaps[i] = gap }
            else if let i = gaps.lastIndex(where: { !$0.resolved && $0.reason == gap.reason && gap.start >= $0.start && gap.start <= $0.end + 0.25 }) {
                gaps[i].end = max(gaps[i].end, gap.end)
            } else { gaps.append(gap) }
            lesson.gaps = gaps
        case .paragraph(let value):
            var values = lesson.paragraphTranslations ?? []
            values.removeAll { $0.id == value.id }; values.append(value); lesson.paragraphTranslations = values
        case .structuredInsight(let value):
            lesson.structuredInsight = value; lesson.topic = value.topic
            lesson.keyPoints = value.keyPoints.map { "• " + $0.text }.joined(separator: "\n")
        case .studyDraft(let value):
            var values = lesson.studyDrafts ?? []; values.append(value); lesson.studyDrafts = values
        case .aiRequest: lesson.aiRequests = (lesson.aiRequests ?? 0) + 1
        case .digestSection(let value):
            var values = lesson.digest ?? []
            if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value } else { values.append(value) }
            lesson.digest = values.sorted { $0.start < $1.start }
        case .focus(let value): lesson.focus = value
        case .aiCall(let value): lesson.aiCalls = (lesson.aiCalls ?? []) + [value]
        case .articleParagraph(let value):
            var values = lesson.article ?? []
            if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value } else { values.append(value) }
            lesson.article = values.sorted { $0.start < $1.start }
        case .filed(let value): lesson.filing = value
        case .bound(let value):
            var values = lesson.bindings ?? []
            values.removeAll { $0.courseID == value.courseID }
            values.append(value); lesson.bindings = values
        case .exported(let value):
            // 只保留最近 30 条，足够界面显示与排查。
            lesson.receipts = Array(((lesson.receipts ?? []) + [value]).suffix(30))
        case .recordedAt(let value): lesson.recordedAt = value
        }
    }
}

public enum LessonText {
    public static func time(_ seconds: Double, milliseconds: Bool = false) -> String {
        let ms = Int(max(0, seconds.isFinite ? seconds : 0) * 1000)
        if milliseconds { return String(format: "%02d:%02d:%02d.%03d", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000) }
        return String(format: "%02d:%02d", ms / 60000, ms / 1000 % 60)
    }

    /// 投影与导出文件名；包含旧版名称，便于清理本机资料夹里的过期投影。
    public static let projectionNames = ["课堂转录.txt", "课堂转录.vtt", "双语.md", "我的笔记.md", "课堂问答.md", "课堂纪要.md", "课堂总结.md",
                                         "重点与话题.md", "笔记整理候选.md", "识别缺口.md", "记录信息.md", "整段译文.md", "我的批注.md"]

    /// 导出时可选的文件，按界面上的顺序：（文件名, 显示名, 说明）。旧版名称不在此列。
    public static let exportCatalog: [(file: String, title: String, detail: String)] = [
        ("课堂总结.md", "课堂总结", "AI 按课堂进度续写的中文笔记"),
        ("课堂纪要.md", "课堂纪要", "按话题分节的要点"),
        ("双语.md", "双语字幕", "英文段落与中文译文"),
        ("课堂转录.txt", "英文原文", "纯文本，每句一行"),
        ("课堂转录.vtt", "字幕文件", "带时间轴的 VTT，可配合录音播放"),
        ("我的笔记.md", "我的笔记", "笔记与没听懂/重点标记"),
        ("课堂问答.md", "AI 问答", "课上课后的提问与回答"),
        ("笔记整理候选.md", "笔记整理", "AI 整理的笔记候选"),
        ("重点与话题.md", "重点与话题", "旧版课堂的话题记录"),
        ("识别缺口.md", "识别缺口", "没有识别到文字的时间段"),
        ("记录信息.md", "记录信息", "音源、时长与识别引擎"),
    ]

    static let phaseNames = ["definition": "定义", "example": "举例", "derivation": "推导", "qa": "问答", "transition": "过渡", "review": "回顾"]

    /// 公开文件只写有内容的部分；引用一律显示为课堂时间，不暴露内部 ID。
    public static func files(for lesson: Lesson) -> [String: String] {
        let lines = lesson.lines
        func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        func cite(_ text: String) -> String { CitationText.render(text, lines: lines) }
        var files: [String: String] = [:]
        if !lines.isEmpty {
            files["课堂转录.txt"] = lines.map { clean($0.original) }.joined(separator: "\n") + "\n"
            files["课堂转录.vtt"] = "WEBVTT\n\n" + lines.map {
                "\(time($0.start, milliseconds: true)) --> \(time(max($0.start + 0.01, $0.end), milliseconds: true))\n\(clean($0.original).replacingOccurrences(of: "-->", with: "→"))\n"
            }.joined(separator: "\n")
        }
        let paragraphs = TranscriptLayout.items(for: lesson).compactMap { item -> DisplayParagraph? in
            if case .paragraph(let value) = item { return value } else { return nil }
        }
        if paragraphs.contains(where: { $0.chinese != .none }) {
            let body = paragraphs.map { paragraph in
                var block = "## \(time(paragraph.start))\n\n\(paragraph.english)"
                if let chinese = paragraph.chineseText(fallback: { _ in "〔未翻译〕" }) { block += "\n\n\(chinese)" }
                return block
            }.joined(separator: "\n\n")
            files["双语.md"] = "# \(lesson.title)\n\n实时识别与机器翻译，未经人工校对。\n\n" + body + "\n"
        }
        let notes = lesson.notes.filter { !$0.deleted }.sorted { TranscriptLayout.noteTime($0) < TranscriptLayout.noteTime($1) }
        if !notes.isEmpty {
            files["我的笔记.md"] = "# 我的笔记 · \(lesson.title)\n\n" + notes.map { note in
                var heading = "## \(note.mediaTime.map { time($0) } ?? "未关联时间")"
                switch note.mark {
                case .confused: heading += " · 没听懂"
                case .important: heading += " · 重点"
                case nil: break
                }
                if let recorded = note.recordedMediaTime, let anchor = note.mediaTime, abs(recorded - anchor) > 2 {
                    heading += "（记录于 \(time(recorded))）"
                }
                var block = heading
                if let quote = note.quote.map(clean), !quote.isEmpty { block += "\n\n> " + quote.replacingOccurrences(of: "\n", with: "\n> ") }
                if let translated = note.translatedQuote.map(clean), !translated.isEmpty { block += "\n>\n> " + translated.replacingOccurrences(of: "\n", with: "\n> ") }
                if !clean(note.text).isEmpty { block += "\n\n" + clean(note.text) }
                return block
            }.joined(separator: "\n\n") + "\n"
        }
        if !lesson.answers.isEmpty {
            files["课堂问答.md"] = "# AI 问答 · \(lesson.title)\n\n回答由 AI 根据课堂原文生成，方括号中的时间是引用的原文位置。\n\n" + lesson.answers.map {
                "## \(clean($0.question))\n\n\(cite(clean($0.answer)))"
            }.joined(separator: "\n\n") + "\n"
        }
        if let article = lesson.article, !article.isEmpty {
            files["课堂总结.md"] = "# 课堂总结 · \(lesson.title)\n\nAI 按课堂进度续写的笔记，每段前是对应的课堂时间。\n\n"
                + article.map { "**\(time($0.start))**　\($0.text)" }.joined(separator: "\n\n") + "\n"
        }
        if let sections = lesson.digest, !sections.isEmpty {
            files["课堂纪要.md"] = "# 课堂纪要 · \(lesson.title)\n\nAI 根据课堂原文整理，括号中的时间是依据的原文位置。\n\n" + sections.map { section in
                var text = "## \(time(section.start))–\(time(section.end)) \(section.title)\n\n"
                if !section.summary.isEmpty { text += section.summary + "\n\n" }
                text += section.points.map { point in
                    let refs = point.sources.compactMap { id in lines.first { $0.id == id }.map { time($0.start) } }
                    return "- 【\(LectureDigest.kinds[point.kind] ?? "重点")】\(point.text)" + (refs.isEmpty ? "" : "（\(refs.joined(separator: "、"))）")
                }.joined(separator: "\n")
                return text
            }.joined(separator: "\n\n") + "\n"
        } else if let state = lesson.structuredInsight {
            var text = "# \(state.topic)\n\n"
            if !state.subtopic.isEmpty { text += "\(state.subtopic)\n\n" }
            text += "阶段：\(phaseNames[state.phase] ?? state.phase)\n\n"
            if !state.vibe.isEmpty { text += "提示：\(state.vibe)\n\n" }
            if !state.summaryDelta.isEmpty { text += "\(state.summaryDelta)\n\n" }
            text += "## 重点\n\n" + state.keyPoints.map { point in
                let refs = point.sourceSegmentIDs.compactMap { id in lines.first { $0.id == id }.map { time($0.start) } }
                return "- \(point.text)" + (refs.isEmpty ? "" : "（\(refs.joined(separator: "、"))）")
            }.joined(separator: "\n")
            files["重点与话题.md"] = text + "\n"
        } else if !lesson.topic.isEmpty {
            files["重点与话题.md"] = "# \(lesson.topic)\n\n\(lesson.keyPoints)\n"
        }
        if let drafts = lesson.studyDrafts, !drafts.isEmpty {
            files["笔记整理候选.md"] = "# 笔记整理（AI 生成，未修改原笔记）\n\n" + drafts.map { cite(clean($0.text)) }.joined(separator: "\n\n---\n\n") + "\n"
        }
        if let gaps = lesson.gaps, !gaps.isEmpty {
            files["识别缺口.md"] = "# 识别缺口\n\n" + gaps.map { "- \(time($0.start))–\(time($0.end))：\($0.resolved ? "已补识别" : "待补识别")（\($0.reason)）" }.joined(separator: "\n") + "\n"
        }
        files["记录信息.md"] = "# \(lesson.title)\n\n音源：\(lesson.source)\n\n状态：\(lesson.phase.rawValue)\n\n时长：\(time(lesson.duration))\n\n引擎：\(Set(lines.compactMap(\.engine)).sorted().joined(separator: ", "))\n\n实时识别稿，未经人工校对；仅在选择连同录音导出时生成独立 m4a 文件。\n\n" + lesson.issues.joined(separator: "\n\n") + "\n"
        return files
    }
}
