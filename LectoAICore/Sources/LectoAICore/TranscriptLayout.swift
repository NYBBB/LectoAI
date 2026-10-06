import Foundation

/// 笔记的快捷标记。存为字符串，未来新增类型时旧版本仍能读取记录。
public enum NoteMark: String, Sendable, CaseIterable {
    case confused, important
}

public extension LessonNote {
    var mark: NoteMark? {
        get { kind.flatMap(NoteMark.init(rawValue:)) }
        set { kind = newValue?.rawValue }
    }
}

/// 段落中的一句原文，以及它的逐句译文（如有）。
public struct DisplaySentence: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let start: Double
    public let end: Double
    public let text: String
    public let translation: String?
    public let flagged: Bool
}

/// 一段中文的来源：整段译文已到达、仍是逐句草稿，或还没有任何译文。
public enum ParagraphChinese: Equatable, Sendable {
    /// 整段重译结果，替换同一位置的草稿。
    case polished(String)
    /// 逐句译文按顺序拼接；`nil` 表示这句还没有译文。
    case draft([String?])
    case none
}

/// 界面阅读单位：一段英文和紧跟其后的中文，二者始终在同一位置更新。
public struct DisplayParagraph: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sentences: [DisplaySentence]
    public let chinese: ParagraphChinese
    /// 仍在录音中的最后一段，后续句子与临时文字会继续接在这里。
    public let isOpen: Bool
    /// 最后一句所属的识别运行；暂停后继续会换运行并另起一段。
    public let runID: UUID
    public let notes: [LessonNote]
    public var start: Double { sentences.first?.start ?? 0 }
    public var end: Double { sentences.last?.end ?? 0 }
    public var english: String { sentences.map(\.text).joined(separator: " ") }
    public var lineIDs: [UUID] { sentences.map(\.id) }

    /// 中文模式与复制时使用的整段中文；缺少译文的句子用 `fallback` 处理。
    public func chineseText(fallback: (DisplaySentence) -> String? = { _ in nil }) -> String? {
        switch chinese {
        case .polished(let text): return text
        case .draft(let pieces):
            let parts = zip(sentences, pieces).compactMap { sentence, piece in piece ?? fallback(sentence) }
            return parts.isEmpty ? nil : parts.joined()
        case .none:
            let parts = sentences.compactMap(fallback)
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }
}

public enum TranscriptItem: Identifiable, Equatable, Sendable {
    case paragraph(DisplayParagraph)
    case gap(RecognitionGap)
    public var id: UUID {
        switch self {
        case .paragraph(let value): value.id
        case .gap(let value): value.id
        }
    }
}

public enum TranscriptLayout {
    /// 与段落重译完全相同的分段规则，保证整段译文能原位替换对应草稿。
    public static func items(for lesson: Lesson) -> [TranscriptItem] {
        let groups = ParagraphAssembler.groups(for: lesson)
        let live = lesson.phase == .recording
        let visibleNotes = lesson.notes.filter { !$0.deleted }
        var notesByParagraph: [Int: [LessonNote]] = [:]
        for note in visibleNotes {
            if let index = paragraphIndex(for: note, in: groups) { notesByParagraph[index, default: []].append(note) }
        }
        var paragraphs: [DisplayParagraph] = []
        for (index, group) in groups.enumerated() {
            let sentences = group.lines.map { line in
                DisplaySentence(id: line.id, start: line.start, end: line.end,
                                text: line.original.trimmingCharacters(in: .whitespacesAndNewlines),
                                translation: line.translation.map(ChineseSpacing.normalize),
                                flagged: !(line.flags ?? []).isEmpty)
            }
            let chinese: ParagraphChinese
            if let polished = group.translation(in: lesson).map(ChineseSpacing.normalize), !polished.isEmpty {
                chinese = .polished(polished)
            } else if sentences.contains(where: { $0.translation?.isEmpty == false }) {
                chinese = .draft(sentences.map { $0.translation?.isEmpty == false ? $0.translation : nil })
            } else { chinese = .none }
            let notes = (notesByParagraph[index] ?? []).sorted { noteTime($0) < noteTime($1) }
            paragraphs.append(DisplayParagraph(id: group.id, sentences: sentences, chinese: chinese,
                                               isOpen: live && index == groups.count - 1, runID: group.lines[group.lines.count - 1].runID, notes: notes))
        }
        // 缺口按时间插入对应位置，而不是全部堆在顶部。
        var items: [TranscriptItem] = []
        var pendingGaps = (lesson.gaps ?? []).sorted { $0.start < $1.start }
        for paragraph in paragraphs {
            while let gap = pendingGaps.first, gap.start <= paragraph.start {
                items.append(.gap(gap)); pendingGaps.removeFirst()
            }
            items.append(.paragraph(paragraph))
        }
        items.append(contentsOf: pendingGaps.map(TranscriptItem.gap))
        return items
    }

    /// 没有落在任何段落里的笔记（例如开课前、或尚无字幕时记下的）。
    public static func looseNotes(for lesson: Lesson) -> [LessonNote] {
        let groups = ParagraphAssembler.groups(for: lesson)
        return lesson.notes.filter { !$0.deleted && paragraphIndex(for: $0, in: groups) == nil }
            .sorted { noteTime($0) < noteTime($1) }
    }

    /// 包含某句的段落 ID，用于跳转与高亮。
    public static func paragraphID(containing lineID: UUID, in lesson: Lesson) -> UUID? {
        ParagraphAssembler.groups(for: lesson).first { $0.lines.contains { $0.id == lineID } }?.id
    }

    /// 某个媒体时间正在播放的句子。
    public static func line(at time: Double, in lesson: Lesson) -> TranscriptLine? {
        lesson.lines.last { $0.start <= time + 0.05 } .flatMap { $0.end + 1.5 >= time ? $0 : nil }
    }

    static func noteTime(_ note: LessonNote) -> Double { note.recordedMediaTime ?? note.mediaTime ?? 0 }

    private static func paragraphIndex(for note: LessonNote, in groups: [TranscriptParagraph]) -> Int? {
        if let segment = note.segmentID, let index = groups.firstIndex(where: { $0.lines.contains { $0.id == segment } }) {
            return index
        }
        // 未绑定句子的标记按记录时刻归到当时正在讲的段落；没有字幕的时刻不强行关联。
        guard let time = note.recordedMediaTime ?? note.mediaTime else { return nil }
        return groups.lastIndex { $0.lines[0].start <= time + 0.5 }
    }
}

/// 机器翻译常在中文句号后留下英文空格（“吧。 今天”）；只去掉两侧都是中文字符或中文标点的空白。
public enum ChineseSpacing {
    private static let cjk = "\\p{Han}。，、；：？！“”‘’（）《》【】「」『』…—"
    private static let pattern = try! NSRegularExpression(pattern: "(?<=[\(cjk)])[ \\t\\u00A0\\u3000]+(?=[\(cjk)])")

    public static func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return pattern.stringByReplacingMatches(in: trimmed, range: range, withTemplate: "")
    }
}

public enum CitationText {
    /// 把回答中的引用（课堂时间、UUID 或 UUID 前 8 位）换成可读时间；`link` 为 nil 时输出纯文本 `[12:03]`。
    public static func render(_ text: String, lines: [TranscriptLine], link: ((UUID, String) -> String)? = nil) -> String {
        LineRef.render(text, lines: lines) { id, time in link?(id, time) ?? "[\(time)]" }
    }
}
