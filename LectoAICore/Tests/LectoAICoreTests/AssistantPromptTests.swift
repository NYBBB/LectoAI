import XCTest
@testable import LectoAICore

final class AssistantPromptTests: XCTestCase {
    func testLiveContextUsesRecentWindowMemoryAndKeywords() {
        var lesson = Lesson(title: "CS 4824", source: "麦克风")
        let run = UUID()
        let old = TranscriptLine(start: 60, end: 64, original: "The Gini index measures impurity.", runID: run)
        let middle = TranscriptLine(start: 600, end: 604, original: "Something unrelated in the middle.", runID: run)
        let recent = TranscriptLine(start: 1150, end: 1154, original: "Now we choose the split threshold s.", runID: run)
        for line in [old, middle, recent] { LessonReducer.apply(.line(line), to: &lesson) }
        LessonReducer.apply(.articleParagraph(ArticleParagraph(start: 60, end: 604, text: "老师介绍了基尼系数（Gini index）。")), to: &lesson)
        LessonReducer.apply(.focus(LiveFocus(topic: "回归树切分", phase: "derivation", hint: "", at: 1150)), to: &lesson)
        let context = AssistantPrompt.context(for: lesson, now: 1160, live: true, selected: [], question: "What is the gini index again?")
        XCTAssertTrue(context.contains("已录约 19 分钟"))
        XCTAssertTrue(context.contains("当前话题：回归树切分（推导）"))
        XCTAssertTrue(context.contains("【前面讲过】"))
        XCTAssertTrue(context.contains("[19:10] Now we choose the split threshold s."), "最近 5 分钟原文带课堂时间")
        XCTAssertFalse(context.contains("Something unrelated"), "5 分钟以前且不相关的原文不进上下文")
        XCTAssertTrue(context.contains("[01:00] The Gini index measures impurity."), "按关键词找回早先原文")
        XCTAssertFalse(context.contains(old.id.uuidString))
    }

    func testSelectedLinesComeFirstAndReviewFallsBackWithoutMemory() {
        var lesson = Lesson(title: "CS", source: "麦克风")
        let run = UUID()
        let a = TranscriptLine(start: 10, end: 12, original: "Alpha sentence.", runID: run)
        let b = TranscriptLine(start: 20, end: 22, original: "Beta sentence.", runID: run)
        for line in [a, b] { LessonReducer.apply(.line(line), to: &lesson) }
        let context = AssistantPrompt.context(for: lesson, now: 22, live: false, selected: [a.id], question: "解释一下")
        XCTAssertTrue(context.contains("【学生问的这段】\n[00:10] Alpha sentence."))
        XCTAssertTrue(context.contains("【课堂原文摘录】"))
        XCTAssertTrue(context.contains("Beta sentence."))
    }
}
