import XCTest
@testable import LectoAICore

final class TranscriptLayoutTests: XCTestCase {
    private func lesson(_ phase: LessonPhase = .recording) -> Lesson {
        var value = Lesson(title: "算法", source: "麦克风")
        value.phase = phase
        return value
    }

    private func line(_ start: Double, _ text: String, run: UUID) -> TranscriptLine {
        TranscriptLine(start: start, end: start + 2, original: " \(text)", runID: run)
    }

    func testDraftTranslationIsReplacedInPlaceByParagraphTranslation() {
        let run = UUID()
        var value = lesson()
        let a = line(0, "Greedy picks the local best.", run: run), b = line(2.5, "It is not always optimal.", run: run)
        for item in [a, b] { LessonReducer.apply(.line(item), to: &value) }
        LessonReducer.apply(.translation(a.id, 1, "贪心选择局部最优。"), to: &value)

        guard case .paragraph(let draft) = TranscriptLayout.items(for: value).first else { return XCTFail("缺少段落") }
        XCTAssertTrue(draft.isOpen)
        XCTAssertEqual(draft.english, "Greedy picks the local best. It is not always optimal.")
        XCTAssertEqual(draft.chinese, .draft(["贪心选择局部最优。", nil]))
        XCTAssertEqual(draft.chineseText(), "贪心选择局部最优。")

        // 段落闭合后整段译文到达：同一段落 ID、同一位置，只替换中文。
        LessonReducer.apply(.translation(b.id, 1, "它并不总是最优。"), to: &value)
        LessonReducer.apply(.phase(.completed, 5), to: &value)
        let group = ParagraphAssembler.groups(value.lines)[0]
        LessonReducer.apply(.paragraph(.init(id: group.id, fingerprint: group.fingerprint, text: "贪心算法每步选局部最优，但结果不一定全局最优。")), to: &value)
        let items = TranscriptLayout.items(for: value)
        XCTAssertEqual(items.count, 1)
        guard case .paragraph(let polished) = items[0] else { return XCTFail("缺少段落") }
        XCTAssertEqual(polished.id, draft.id)
        XCTAssertFalse(polished.isOpen)
        XCTAssertEqual(polished.chinese, .polished("贪心算法每步选局部最优，但结果不一定全局最优。"))
    }

    func testStaleParagraphTranslationFallsBackToSentenceDraft() {
        let run = UUID()
        var value = lesson(.completed)
        var a = line(0, "One.", run: run)
        LessonReducer.apply(.line(a), to: &value)
        let group = ParagraphAssembler.groups(value.lines)[0]
        LessonReducer.apply(.paragraph(.init(id: group.id, fingerprint: group.fingerprint, text: "旧整段")), to: &value)
        a.revision = 2; a.original = "One, corrected."
        LessonReducer.apply(.line(a), to: &value)
        LessonReducer.apply(.translation(a.id, 2, "一，已更正。"), to: &value)
        guard case .paragraph(let paragraph) = TranscriptLayout.items(for: value).first else { return XCTFail("缺少段落") }
        XCTAssertEqual(paragraph.chinese, .draft(["一，已更正。"]))
    }

    func testNotesAndGapsAreGroupedByTime() {
        let run = UUID()
        var value = lesson()
        let first = line(0, "First paragraph.", run: run)
        let second = line(20, "Second paragraph.", run: run)
        for item in [first, second] { LessonReducer.apply(.line(item), to: &value) }
        var bound = LessonNote(line: first, mediaTime: 1, text: "绑定第一句")
        bound.mark = .important
        let unbound = LessonNote(line: nil, mediaTime: 23)
        var removed = LessonNote(line: second, mediaTime: 21)
        removed.deleted = true
        for note in [bound, unbound, removed] { LessonReducer.apply(.note(note), to: &value) }
        LessonReducer.apply(.gap(RecognitionGap(start: 8, end: 15, reason: "识别中断")), to: &value)

        let items = TranscriptLayout.items(for: value)
        XCTAssertEqual(items.count, 3)
        guard case .paragraph(let p1) = items[0], case .gap = items[1], case .paragraph(let p2) = items[2] else { return XCTFail("顺序错误") }
        XCTAssertEqual(p1.notes.map(\.id), [bound.id])
        XCTAssertEqual(p1.notes.first?.mark, .important)
        XCTAssertEqual(p2.notes.map(\.id), [unbound.id])
        XCTAssertTrue(TranscriptLayout.looseNotes(for: value).isEmpty)
    }

    func testExportUsesReadableCitationsAndSkipsEmptyFiles() {
        let run = UUID()
        var value = lesson(.completed)
        let a = line(63, "Exec does not return.", run: run)
        LessonReducer.apply(.line(a), to: &value)
        LessonReducer.apply(.translation(a.id, 1, "exec 不会返回。"), to: &value)
        LessonReducer.apply(.answer(LessonAnswer(question: "为什么？", answer: "因为进程映像被替换 [\(a.id.uuidString)]。", citations: [a.id])), to: &value)
        let files = LessonText.files(for: value)
        XCTAssertEqual(files["课堂问答.md"]?.contains("[01:03]"), true)
        XCTAssertEqual(files["课堂问答.md"]?.contains(a.id.uuidString), false)
        XCTAssertEqual(files["双语.md"]?.contains("exec 不会返回。"), true)
        XCTAssertNil(files["我的笔记.md"])
        XCTAssertNil(files["识别缺口.md"])
        XCTAssertNil(files["整段译文.md"])
        XCTAssertEqual(files["课堂转录.txt"], "Exec does not return.\n")
    }

    func testOldNoteRecordsWithoutKindStillDecode() throws {
        let note = LessonNote(line: nil, mediaTime: 3, text: "旧记录")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as! [String: Any]
        object.removeValue(forKey: "kind")
        let decoded = try JSONDecoder().decode(LessonNote.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.mark)
        XCTAssertEqual(decoded.text, "旧记录")
    }
}

final class ChineseSpacingTests: XCTestCase {
    func testRemovesMachineTranslationSpacesOnlyBetweenChinese() {
        XCTAssertEqual(ChineseSpacing.normalize("好的，我们开始吧。 今天我们讨论贪心算法。 "), "好的，我们开始吧。今天我们讨论贪心算法。")
        XCTAssertEqual(ChineseSpacing.normalize("exec 成功时不会返回。 所以 fork 之后"), "exec 成功时不会返回。所以 fork 之后")
        XCTAssertEqual(ChineseSpacing.normalize("使用 close-on-exec 标志"), "使用 close-on-exec 标志")
    }
}
