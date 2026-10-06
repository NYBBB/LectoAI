import XCTest
@testable import LectoAICore

final class LectureArticleTests: XCTestCase {
    private func lesson(_ count: Int, spacing: Double = 6) -> Lesson {
        var value = Lesson(title: "CS 4824", source: "麦克风")
        let run = UUID()
        for index in 0..<count {
            LessonReducer.apply(.line(TranscriptLine(start: Double(index) * spacing, end: Double(index) * spacing + 4, original: "Sentence \(index).", runID: run)), to: &value)
        }
        return value
    }

    func testWaitsForEnoughContentThenContinuesFromLastParagraph() throws {
        var value = lesson(5)
        XCTAssertFalse(LectureArticle.isDue(value, final: false), "5 句、约 30 秒，还不够续写")
        XCTAssertTrue(LectureArticle.isDue(value, final: true), "暂停/结束时写完尾巴")
        value = lesson(9)
        XCTAssertTrue(LectureArticle.isDue(value, final: false))
        let first = try XCTUnwrap(LectureArticle.request(for: value))
        XCTAssertFalse(first.user.contains("【已有文章】"))
        XCTAssertTrue(first.user.contains("Sentence 0.") && first.user.contains("Sentence 8."))
        let paragraph = try LectureArticle.parse("## 标题\n- 老师 先 回顾 了 决策树。\n\n然后讲回归树（regression tree）。", lines: first.lines)
        XCTAssertEqual(paragraph.text, "老师先回顾了决策树。\n\n然后讲回归树（regression tree）。")
        XCTAssertEqual(paragraph.start, 0)
        XCTAssertEqual(paragraph.end, 52)
        LessonReducer.apply(.articleParagraph(paragraph), to: &value)
        XCTAssertFalse(LectureArticle.isDue(value, final: true), "已写进文章的原文不再续写")
        for index in 9..<18 {
            LessonReducer.apply(.line(TranscriptLine(start: Double(index) * 6, end: Double(index) * 6 + 4, original: "Sentence \(index).", runID: value.lines[0].runID)), to: &value)
        }
        let second = try XCTUnwrap(LectureArticle.request(for: value))
        XCTAssertTrue(second.user.contains("【已有文章】"))
        XCTAssertTrue(second.user.contains("【上一段原文】"))
        XCTAssertFalse(second.user.split(separator: "【新增原文】").last!.contains("Sentence 8."), "新增原文不含已写过的句子")
        XCTAssertEqual(LessonText.files(for: value)["课堂总结.md"]?.contains("**00:00**"), true)
    }

    func testParagraphsUseCorrectedEnglishWhenAvailable() throws {
        var value = lesson(9, spacing: 3)
        let groups = ParagraphAssembler.groups(for: value)
        LessonReducer.apply(.paragraph(.init(id: groups[0].id, fingerprint: groups[0].fingerprint, text: "中文", engine: "ai", english: "Corrected paragraph.")), to: &value)
        let request = try XCTUnwrap(LectureArticle.request(for: value))
        XCTAssertTrue(request.user.contains("Corrected paragraph."))
        XCTAssertThrowsError(try LectureArticle.parse("  ", lines: request.lines))
    }
}
