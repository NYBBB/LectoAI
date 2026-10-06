import Foundation

/// AI 引用课堂原文的方式：给模型看的是课堂时间 `[mm:ss]`，不再给 UUID。
/// 实测 glm 等模型会把 36 位 UUID 缩写成前 8 位，导致整次纪要被判为引用无效（2026-09-29 课堂）。
/// 解析时兼容三种写法：课堂时间、完整 UUID（旧回答）、UUID 前 8 位。
public enum LineRef {
    /// 给模型看的引用标签。
    public static func label(_ line: TranscriptLine) -> String { LessonText.time(line.start) }

    /// 在候选句子中解析一个引用；时间允许 ±3 秒误差，取最接近的一句。
    public static func resolve(_ token: String, in lines: [TranscriptLine]) -> TranscriptLine? {
        let raw = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: raw) { return lines.first { $0.id == id } }
        if raw.count == 8, raw.allSatisfy(\.isHexDigit) {
            let prefix = raw.uppercased()
            return lines.first { $0.id.uuidString.hasPrefix(prefix) }
        }
        guard let seconds = seconds(raw) else { return nil }
        if let exact = lines.first(where: { Int($0.start) == seconds }) { return exact }
        return lines.filter { abs($0.start - Double(seconds)) <= 3 }.min { abs($0.start - Double(seconds)) < abs($1.start - Double(seconds)) }
    }

    /// `mm:ss` 或 `h:mm:ss` 转秒；分钟可以超过 59（课堂时间按分:秒书写）。
    static func seconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) }) else { return nil }
        let values = parts.compactMap(Int.init)
        guard values.count == parts.count, values.last! < 60 else { return nil }
        return values.count == 2 ? values[0] * 60 + values[1] : values[0] * 3600 + values[1] * 60 + values[2]
    }

    private static let bracket = try! NSRegularExpression(pattern: #"\[([^\[\]\n]{4,120})\]"#)

    /// 方括号内可能是一个或多个引用（逗号、顿号分隔），也可能是时间段 `06:36–09:29`（取开头那句，保留原样的标签）。
    /// 全部能解析时才视为引用，否则保持原文（例如 Markdown 链接文字）。
    static func refs(inBracket content: String, lines: [TranscriptLine]) -> [(line: TranscriptLine, label: String)]? {
        let tokens = content.split(whereSeparator: { ",，、;；".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !tokens.isEmpty else { return nil }
        var found: [(TranscriptLine, String)] = []
        for token in tokens {
            if let range = token.range(of: #"^\d{1,3}:\d{2}(:\d{2})?\s*[–—~\-至到]\s*\d{1,3}:\d{2}(:\d{2})?$"#, options: .regularExpression) {
                let head = String(token[range]).split(whereSeparator: { "–—~-至到 ".contains($0) }).first.map(String.init) ?? ""
                guard let line = resolve(head, in: lines) else { return nil }
                found.append((line, token.replacingOccurrences(of: " ", with: "")))
            } else if let line = resolve(token, in: lines) {
                found.append((line, label(line)))
            } else { return nil }
        }
        return found
    }

    /// 文本中所有能解析到候选句子的引用（去重，按出现顺序）。
    public static func citations(in text: String, lines: [TranscriptLine]) -> [UUID] {
        let ns = text as NSString
        var ids: [UUID] = []
        for match in bracket.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            for ref in refs(inBracket: ns.substring(with: match.range(at: 1)), lines: lines) ?? [] where !ids.contains(ref.line.id) {
                ids.append(ref.line.id)
            }
        }
        return ids
    }

    /// 把引用换成 `link(id, 时间)` 的结果；无法解析的方括号保持原样。
    public static func render(_ text: String, lines: [TranscriptLine], link: (UUID, String) -> String) -> String {
        let ns = text as NSString
        var output = ""
        var cursor = 0
        var lastWasRef = false
        for match in bracket.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += between
            if let found = refs(inBracket: ns.substring(with: match.range(at: 1)), lines: lines) {
                // 紧挨着上一个引用时加顿号，避免显示成“37:4838:16”。
                if between.isEmpty, lastWasRef { output += "、" }
                output += found.map { link($0.line.id, $0.label) }.joined(separator: "、")
                lastWasRef = true
                cursor = match.range.location + match.range.length
                continue
            } else if UUID(uuidString: ns.substring(with: match.range(at: 1))) != nil {
                // 旧回答引用的句子已被补识别替换
                output += "[来源已更新]"
            } else {
                output += ns.substring(with: match.range)
            }
            lastWasRef = false
            cursor = match.range.location + match.range.length
        }
        return output + ns.substring(from: cursor)
    }
}

/// 一次 AI 调用的记录（O1）：写入课堂事件日志，失败时保留原因与截断的原始输出，便于事后排查。
public struct AICall: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    /// digest 纪要 / answer 问答 / notes 笔记整理 / translate 翻译 / summary 总结文章
    public var kind: String
    public var model: String
    public var at: Date
    /// 调用时的课堂时间（课后为 nil）。
    public var mediaTime: Double?
    public var inputCharacters: Int
    public var outputCharacters: Int
    /// 模型思考部分的字数（不保存内容）；旧记录没有。
    public var reasoningCharacters: Int?
    public var firstTokenSeconds: Double?
    public var totalSeconds: Double
    public var ok: Bool
    public var error: String?
    public var output: String?

    public init(id: UUID = UUID(), kind: String, model: String, at: Date = Date(), mediaTime: Double?, inputCharacters: Int,
                outputCharacters: Int, reasoningCharacters: Int? = nil, firstTokenSeconds: Double?, totalSeconds: Double, ok: Bool, error: String? = nil, output: String? = nil) {
        self.id = id; self.kind = kind; self.model = model; self.at = at; self.mediaTime = mediaTime
        self.inputCharacters = inputCharacters; self.outputCharacters = outputCharacters; self.reasoningCharacters = reasoningCharacters
        self.firstTokenSeconds = firstTokenSeconds; self.totalSeconds = totalSeconds
        self.ok = ok; self.error = error; self.output = output.map { String($0.prefix(8000)) }
    }
}

public enum AIOutput {
    /// 去掉推理模型输出的 `<think>…</think>` 段落，只留正式回答。
    public static func clean(_ text: String) -> String {
        var value = text
        while let open = value.range(of: "<think>"), let close = value.range(of: "</think>", range: open.upperBound..<value.endIndex) {
            value.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
