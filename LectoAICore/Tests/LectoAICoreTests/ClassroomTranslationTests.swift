import XCTest
@testable import LectoAICore

final class ClassroomTranslationTests: XCTestCase {
    func testRequestUsesPreviousCorrectedEnglishAndTopic() {
        let run = UUID()
        let a = TranscriptLine(start: 0, end: 3, original: "We look at the future day.", runID: run)
        let b = TranscriptLine(start: 10, end: 13, original: "Car splits the space.", runID: run)
        var lesson = Lesson(title: "CS 4824", source: "麦克风")
        LessonReducer.apply(.line(a), to: &lesson)
        LessonReducer.apply(.line(b), to: &lesson)
        let groups = ParagraphAssembler.groups(for: lesson)
        XCTAssertEqual(groups.count, 2)
        LessonReducer.apply(.paragraph(.init(id: groups[0].id, fingerprint: groups[0].fingerprint, text: "我们看特征 j。", engine: "ai", english: "We look at feature j.")), to: &lesson)
        LessonReducer.apply(.focus(LiveFocus(topic: "回归树", phase: "derivation", hint: "", at: 5)), to: &lesson)
        let request = ClassroomTranslation.request(for: groups[1], previous: groups[0], lesson: lesson)
        XCTAssertTrue(request.contains("当前话题：回归树"))
        XCTAssertTrue(request.contains("We look at feature j."), "上一段优先用纠正后的英文")
        XCTAssertTrue(request.hasSuffix("Car splits the space."))
    }

    func testParseTwoLinesAndRejectMissingChinese() throws {
        let value = try ClassroomTranslation.parse("<think>x</think>EN: CART splits the feature space.\nZH: CART 把 特征空间 切分开。")
        XCTAssertEqual(value.english, "CART splits the feature space.")
        XCTAssertEqual(value.chinese, "CART 把特征空间切分开。")
        XCTAssertThrowsError(try ClassroomTranslation.parse("CART splits the space."))
    }

    func testNewLessonsUseShortParagraphs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LessonRepository(root: root)
        var lesson = try await repo.create(title: "课", source: "麦克风")
        XCTAssertEqual(lesson.paragraphRule, .compact)
        let run = UUID()
        for index in 0..<6 {
            lesson = try await repo.append(.line(TranscriptLine(start: Double(index * 3), end: Double(index * 3 + 2), original: "Sentence \(index).", runID: run)), to: lesson.id)
        }
        XCTAssertEqual(ParagraphAssembler.groups(for: lesson).map(\.lines.count), [4, 2])
        XCTAssertEqual(ParagraphAssembler.groups(lesson.lines).map(\.lines.count), [6], "旧课堂仍按 8 句规则")
    }
}
