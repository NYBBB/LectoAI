import XCTest
@testable import LectoAICore

final class LessonRepositoryTests: XCTestCase {
    func testRecoveryRetainsQuotedNotesAndRejectsStaleTranslation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LessonRepository(root: root)
        let lesson = try await repository.create(title: "测试", source: "file")
        var line = TranscriptLine(start: 2, end: 4, original: "Original", runID: UUID())
        try await repository.append(.line(line), to: lesson.id)
        let note = LessonNote(line: line, mediaTime: 5, text: "保持引用")
        try await repository.append(.note(note), to: lesson.id)
        line.revision = 2; line.original = "Corrected"
        try await repository.append(.line(line), to: lesson.id)
        try await repository.append(.translation(line.id, 1, "过期"), to: lesson.id)
        let recoveredRepository = try LessonRepository(root: root)
        let recovered = try await recoveredRepository.recover()
        XCTAssertEqual(recovered.first?.phase, .interrupted)
        XCTAssertNil(recovered.first?.lines.first?.translation)
        XCTAssertEqual(recovered.first?.notes.first?.quote, "Original")
        XCTAssertEqual(recovered.first?.notes.first?.mediaTime, 2)
    }

    func testTruncatedTailIsIsolatedAndExportNeverOverwrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LessonRepository(root: root)
        let lesson = try await repository.create(title: "../课程", source: "file")
        let directory = await repository.directory(lesson.id)
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("events.jsonl"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken".utf8)); try handle.close()
        let fresh = try LessonRepository(root: root)
        let loaded = try await fresh.load(lesson.id)
        XCTAssertEqual(loaded.id, lesson.id)
        let first = try await fresh.export(lesson.id, into: root, includeAudio: false)
        let sentinel = first.appendingPathComponent("课堂转录.txt")
        try Data("user edit".utf8).write(to: sentinel)
        let second = try await fresh.export(lesson.id, into: root, includeAudio: false)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "user edit")
        XCTAssertEqual(first.deletingLastPathComponent().path, root.path)
    }

    func testBrokenRecordDoesNotHideHealthyHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LessonRepository(root: root)
        let bad = try await repository.create(title: "损坏记录", source: "file")
        let good = try await repository.create(title: "完整记录", source: "file")
        let url = await repository.directory(bad.id).appendingPathComponent("events.jsonl")
        try Data("broken\n".utf8).write(to: url)
        let fresh = try LessonRepository(root: root)
        let list = try await fresh.list()
        let warnings = await fresh.recoveryWarnings
        XCTAssertEqual(list.map(\.id), [good.id])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "broken\n")
    }

    func testPauseResumeAndNoteUndoSurviveReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LessonRepository(root: root)
        let lesson = try await repo.create(title: "课堂", source: "microphone")
        try await repo.append(.chunk(.init(file: "a.caf", start: 0, duration: 10)), to: lesson.id)
        try await repo.append(.phase(.paused, 10), to: lesson.id)
        try await repo.append(.phase(.recording, 10), to: lesson.id)
        try await repo.append(.chunk(.init(file: "b.caf", start: 10, duration: 7)), to: lesson.id)
        var note = LessonNote(line: nil, mediaTime: 12, text: "重点")
        try await repo.append(.note(note), to: lesson.id)
        note.deleted = true; try await repo.append(.note(note), to: lesson.id)
        note.deleted = false; try await repo.append(.note(note), to: lesson.id)
        try await repo.append(.phase(.completed, 17), to: lesson.id)
        let fresh = try LessonRepository(root: root)
        let result = try await fresh.load(lesson.id)
        XCTAssertEqual(result.duration, 17)
        XCTAssertEqual(result.notes.count, 1)
        XCTAssertFalse(result.notes[0].deleted)
        XCTAssertEqual(result.notes[0].mediaTime, 12)
        XCTAssertEqual(result.audio[1].start, 10)
        let folder = try await fresh.export(lesson.id, into: root, includeAudio: false)
        let exported = try JSONDecoder().decode(Lesson.self, from: Data(contentsOf: folder.appendingPathComponent("session.json")))
        XCTAssertEqual(exported, result)
    }

    func testAIBudgetPersistsAndOldEvidenceCanBeRetrieved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try LessonRepository(root: root)
        let lesson = try await repo.create(title: "课堂", source: "file")
        try await repo.append(.aiRequest, to: lesson.id)
        let fresh = try LessonRepository(root: root)
        let restored = try await fresh.load(lesson.id)
        XCTAssertEqual(restored.aiRequests, 1)
        let old = TranscriptLine(start: 0, end: 5, original: "The exchange argument proves the greedy choice.", runID: UUID())
        let recent = (1...40).map { TranscriptLine(start: Double($0 * 5), end: Double($0 * 5 + 4), original: String(repeating: "Unrelated content. ", count: 100), runID: UUID()) }
        let context = TextProvider.context(lines: [old] + recent, selected: nil, question: "Explain the exchange argument")
        XCTAssertTrue(context.contains("[00:00] The exchange argument"), "按关键词找回的早期原文，用课堂时间标注")
        XCTAssertLessThanOrEqual(context.count, 19000)
    }

    /// 导出时只勾选部分文件、手动命名：只写选中的文件，文件名用输入的开头；目录里没有其他文件。
    func testManagedExportSelectedFilesWithCustomName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("课程", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let repo = try LessonRepository(root: root.appendingPathComponent("lib"))
        let lesson = try await repo.create(title: "课堂", source: "file")
        try await repo.append(.line(TranscriptLine(start: 0, end: 3, original: "Hello class.", runID: UUID())), to: lesson.id)
        try await repo.append(.articleParagraph(ArticleParagraph(start: 0, end: 3, text: "老师打招呼。")), to: lesson.id)
        _ = try await repo.exportManaged(lesson.id, into: target, naming: ExportNaming(), name: " Week 5: 贪心 ", only: ["课堂总结.md", "课堂转录.txt"])
        let names = try FileManager.default.contentsOfDirectory(atPath: target.path).sorted()
        XCTAssertEqual(names, ["Week 5- 贪心 课堂总结.md", "Week 5- 贪心 课堂转录.txt"])
        XCTAssertThrowsError(try ExportNaming.clean("  "))
        XCTAssertThrowsError(try ExportNaming.clean(".hidden"))
        XCTAssertEqual(Set(LessonText.exportCatalog.map(\.file)).subtracting(LessonText.projectionNames), [], "可选文件都应是已知投影")
    }

    func testEndpointAndContextBoundaries() throws {
        XCTAssertThrowsError(try ModelProfile(endpoint: "http://example.com/v1", model: "m").url())
        XCTAssertThrowsError(try ModelProfile(endpoint: "https://key@example.com/v1", model: "m").url())
        XCTAssertEqual(try ModelProfile(endpoint: "http://localhost:1234/v1", model: "m").url().path, "/v1/chat/completions")
        XCTAssertEqual(LessonText.time(3661.234, milliseconds: true), "01:01:01.234")
    }
}
