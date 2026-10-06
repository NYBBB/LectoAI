import XCTest
@testable import LectoAICore

/// 交到课程文件夹：固定身份、撞名加序号、认领、外部改动另存、被移走的文件不复活、升级时认领旧账本。
final class HandoffTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var repository: LessonRepository!
    private let course = UUID()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder = root.appendingPathComponent("CS3214/raw/课堂转录", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        repository = try LessonRepository(root: root.appendingPathComponent("lib"))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func makeLesson(_ sentence: String = "Hello class.", filed: Bool = true) async throws -> Lesson {
        let lesson = try await repository.create(title: "课堂", source: "麦克风")
        if filed { try await repository.append(.filed(Filing(courseID: course, courseName: "CS 3214", basis: "asked")), to: lesson.id) }
        return try await repository.append(.line(TranscriptLine(start: 0, end: 3, original: sentence, runID: UUID())), to: lesson.id)
    }

    /// 走完整的三步：取快照 → 写盘 → 登记。
    @discardableResult
    private func handOff(_ id: UUID, base: String, manual: Bool = false, reserved: Set<String> = [], now: Date = Date()) async throws -> (outcome: HandoffOutcome, lesson: Lesson) {
        let snapshot = try await repository.handoffSnapshot(id, courseID: course)
        let outcome = HandoffWriter.write(snapshot, into: folder, basePrefix: base, manual: manual, reserved: reserved, now: now)
        let lesson = try await repository.recordHandoff(snapshot, outcome: outcome, folderName: "课堂转录", timeZoneID: "America/New_York")
        return (outcome, lesson)
    }

    private var names: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
    private func text(_ name: String) throws -> String { try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) }

    func testBindingIsFrozenAfterFirstHandoff() async throws {
        let lesson = try await makeLesson()
        let first = try await handOff(lesson.id, base: "Week 07 - 10-6")
        XCTAssertEqual(first.outcome.prefix, "Week 07 - 10-6")
        XCTAssertEqual(first.lesson.bindings?.first?.prefix, "Week 07 - 10-6")
        XCTAssertEqual(names, ["Week 07 - 10-6 记录信息.md", "Week 07 - 10-6 课堂转录.txt", "Week 07 - 10-6 课堂转录.vtt"])

        // 之后标题变了、算出的开头也变了：仍用第一次定下的开头，不出第二套文件。
        try await repository.append(.title("Virtual Memory"), to: lesson.id)
        try await repository.append(.line(TranscriptLine(start: 4, end: 6, original: "Second sentence.", runID: UUID())), to: lesson.id)
        let second = try await handOff(lesson.id, base: "2026-10-06 Virtual Memory")
        XCTAssertEqual(second.outcome.prefix, "Week 07 - 10-6")
        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(try text("Week 07 - 10-6 课堂转录.txt").contains("Second sentence."))
        XCTAssertEqual(second.lesson.receipts?.count, 2)

        // 内容没变：不写文件，也不多记一条交接。
        let third = try await handOff(lesson.id, base: "whatever")
        XCTAssertEqual(third.outcome.written, 0)
        XCTAssertEqual(third.lesson.receipts?.count, 2)
    }

    func testSecondLessonWithSamePrefixGetsNumberedNotConflictCopies() async throws {
        let first = try await makeLesson("First lesson.")
        let second = try await makeLesson("Second lesson.")
        try await handOff(first.id, base: "Week 07 - 10-6")
        // 外部 Agent 写的同开头文件不算撞名。
        try Data("整理".utf8).write(to: folder.appendingPathComponent("Week 07 - 10-6 整理 - 虚拟内存.md"))
        let outcome = try await handOff(second.id, base: "Week 07 - 10-6").outcome
        XCTAssertEqual(outcome.prefix, "Week 07 - 10-6 (2)")
        XCTAssertTrue(outcome.conflicts.isEmpty)
        XCTAssertTrue(names.contains("Week 07 - 10-6 (2) 课堂转录.txt"))
        XCTAssertFalse(names.contains { $0.contains("LectoAI 更新") })
        XCTAssertEqual(try text("Week 07 - 10-6 课堂转录.txt"), "First lesson.\n")
    }

    func testIdenticalExistingFilesAreAdoptedWithoutRewriting() async throws {
        let lesson = try await makeLesson()
        // 模拟重装前交出的文件：内容与现在要写的完全相同，但本机没有账本。
        let snapshot = try await repository.handoffSnapshot(lesson.id, courseID: course)
        for (name, data) in snapshot.files { try data.write(to: folder.appendingPathComponent("Week 07 - 10-6 \(name)")) }
        let outcome = try await handOff(lesson.id, base: "Week 07 - 10-6").outcome
        XCTAssertEqual(outcome.prefix, "Week 07 - 10-6", "认领，不加序号")
        XCTAssertEqual(outcome.written, 0)
        XCTAssertEqual(names.count, snapshot.files.count)
    }

    func testOwnAudioMarksThePrefixAsOurs() async throws {
        let lesson = try await makeLesson()
        try Data("old".utf8).write(to: folder.appendingPathComponent("Week 07 - 10-6 课堂转录.txt"))
        try Data().write(to: folder.appendingPathComponent("Week 07 - 10-6 录音 \(lesson.id.uuidString.prefix(8)).m4a"))
        let outcome = try await handOff(lesson.id, base: "Week 07 - 10-6").outcome
        XCTAssertEqual(outcome.prefix, "Week 07 - 10-6", "录音文件名带这堂课的编号，开头就是这堂课的")
        XCTAssertEqual(outcome.conflicts.count, 1, "内容不同的旧文件保留，新内容另存")
        XCTAssertEqual(try text("Week 07 - 10-6 课堂转录.txt"), "old")
    }

    func testExternalEditIsKeptAndNewContentSavedAsCopy() async throws {
        let lesson = try await makeLesson()
        try await handOff(lesson.id, base: "Week 07 - 10-6")
        try Data("我改过了".utf8).write(to: folder.appendingPathComponent("Week 07 - 10-6 课堂转录.txt"))
        try await repository.append(.line(TranscriptLine(start: 4, end: 6, original: "New sentence.", runID: UUID())), to: lesson.id)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 10, minute: 47))!
        let result = try await handOff(lesson.id, base: "Week 07 - 10-6", now: now)
        XCTAssertEqual(result.outcome.conflicts, ["Week 07 - 10-6 课堂转录 (LectoAI 更新 1006-1047).txt"])
        XCTAssertEqual(try text("Week 07 - 10-6 课堂转录.txt"), "我改过了")
        XCTAssertTrue(try text("Week 07 - 10-6 课堂转录 (LectoAI 更新 1006-1047).txt").contains("New sentence."))
        if case .conflicted(_, _, let copies) = result.lesson.handoffStatus { XCTAssertEqual(copies.count, 1) } else { XCTFail("应为有冲突副本的状态") }

        // 之后的更新写到副本上；副本再被改时不叠后缀。
        try await repository.append(.line(TranscriptLine(start: 7, end: 9, original: "Third.", runID: UUID())), to: lesson.id)
        let next = try await handOff(lesson.id, base: "Week 07 - 10-6", now: now).outcome
        XCTAssertTrue(next.conflicts.isEmpty)
        XCTAssertTrue(try text("Week 07 - 10-6 课堂转录 (LectoAI 更新 1006-1047).txt").contains("Third."))
        let copy = folder.appendingPathComponent("Week 07 - 10-6 课堂转录 (LectoAI 更新 1006-1047).txt")
        XCTAssertEqual(HandoffWriter.conflictCopy(of: copy, now: now).lastPathComponent, "Week 07 - 10-6 课堂转录 (LectoAI 更新 1006-1047-2).txt")
        XCTAssertEqual(HandoffWriter.original(ofCopy: copy.lastPathComponent), "Week 07 - 10-6 课堂转录.txt")
        // 没看过的冲突副本延续到后面的记录里；用户看过之后状态回到“已交到”。
        let carried = try await repository.load(lesson.id)
        if case .conflicted(_, _, let copies) = carried.handoffStatus { XCTAssertEqual(copies.count, 1) } else { XCTFail("普通更新不应冲掉冲突提示") }
        let acknowledged = try await repository.acknowledgeConflicts(lesson.id, courseID: course)
        if case .delivered = acknowledged.handoffStatus {} else { XCTFail("看过之后应回到已交到") }
    }

    /// 外部改了文件，而我们这边没有新内容：不另存副本、不覆盖、不多记一条；之后有了新内容才另存。
    func testExternalEditWithoutNewContentCreatesNoCopy() async throws {
        let lesson = try await makeLesson()
        try await handOff(lesson.id, base: "Week 07 - 10-6")
        try Data("改了个错字".utf8).write(to: folder.appendingPathComponent("Week 07 - 10-6 课堂转录.txt"))
        let before = names
        // 一条不改变任何导出内容的事件之后再次触发（例如点了“交到”或“重试”）。
        try await repository.append(.aiRequest, to: lesson.id)
        let again = try await handOff(lesson.id, base: "Week 07 - 10-6", manual: true)
        XCTAssertEqual(again.outcome.written, 0)
        XCTAssertTrue(again.outcome.conflicts.isEmpty)
        XCTAssertEqual(names, before, "没有新内容时不应多出任何文件")
        XCTAssertEqual(try text("Week 07 - 10-6 课堂转录.txt"), "改了个错字")
        XCTAssertEqual(again.lesson.receipts?.count, 1)
        try await repository.append(.line(TranscriptLine(start: 4, end: 6, original: "Now there is new content.", runID: UUID())), to: lesson.id)
        let later = try await handOff(lesson.id, base: "Week 07 - 10-6").outcome
        XCTAssertEqual(later.conflicts.count, 1, "有了新内容，被改过的文件才另存")
        XCTAssertEqual(try text("Week 07 - 10-6 课堂转录.txt"), "改了个错字")
    }

    /// 写到一半出错：已经写成功的文件照样登记，重试时不会把它们当成外部改动再另存一份。
    func testPartialFailureIsRecordedSoRetryIsIdempotent() async throws {
        let lesson = try await makeLesson()
        try await handOff(lesson.id, base: "Week 07 - 10-6")
        try await repository.append(.line(TranscriptLine(start: 4, end: 6, original: "More content.", runID: UUID())), to: lesson.id)
        // 让“课堂转录.vtt”这一个文件写不进去：把它换成同名目录。按文件名顺序，“课堂转录.txt”会先写成功。
        let vtt = folder.appendingPathComponent("Week 07 - 10-6 课堂转录.vtt")
        try FileManager.default.removeItem(at: vtt)
        try FileManager.default.createDirectory(at: vtt, withIntermediateDirectories: true)
        let failed = try await handOff(lesson.id, base: "Week 07 - 10-6")
        XCTAssertNotNil(failed.outcome.failure)
        XCTAssertEqual(failed.outcome.written, 1, "出错之前写成功的那个文件")
        if case .failed = failed.lesson.handoffStatus {} else { XCTFail("应记为失败") }
        try FileManager.default.removeItem(at: vtt)
        let retried = try await handOff(lesson.id, base: "Week 07 - 10-6", manual: true)
        XCTAssertNil(retried.outcome.failure)
        XCTAssertTrue(retried.outcome.conflicts.isEmpty, "已经写过的文件不应被当成外部改动")
        XCTAssertEqual(names, ["Week 07 - 10-6 记录信息.md", "Week 07 - 10-6 课堂转录.txt", "Week 07 - 10-6 课堂转录.vtt"], "重试后只有一套文件")
        if case .delivered = retried.lesson.handoffStatus {} else { XCTFail("重试成功后应为已交到") }
    }

    /// 第一次交接就失败（文件夹暂时不可写）：开头照样定下，重试时不会换成别的开头再写一套。
    func testFirstHandoffFailureStillFixesThePrefix() async throws {
        let lesson = try await makeLesson()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let failed = try await handOff(lesson.id, base: "Week 07 - 10-6")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        XCTAssertNotNil(failed.outcome.failure)
        XCTAssertEqual(failed.lesson.bindings?.first?.prefix, "Week 07 - 10-6", "失败时也要定下开头")
        if case .failed = failed.lesson.handoffStatus {} else { XCTFail("应记为失败") }
        let retried = try await handOff(lesson.id, base: "这次算出来的是别的开头")
        XCTAssertEqual(retried.outcome.prefix, "Week 07 - 10-6")
        XCTAssertEqual(names.count, 3)
    }

    /// 别的课堂已经定下的开头，即使它的文件被归档走了、文件夹里看不到，也不能再用。
    func testReservedPrefixIsSkippedEvenWhenFolderLooksFree() async throws {
        let morning = try await makeLesson("Morning.")
        try await handOff(morning.id, base: "Week 07 - 10-6")
        for name in names { try FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        let afternoon = try await makeLesson("Afternoon.")
        let outcome = try await handOff(afternoon.id, base: "Week 07 - 10-6", reserved: ["Week 07 - 10-6"]).outcome
        XCTAssertEqual(outcome.prefix, "Week 07 - 10-6 (2)")
    }

    /// 录音单独登记，不影响文字的交接记录。
    func testAudioIsRecordedSeparately() async throws {
        let lesson = try await makeLesson()
        try await handOff(lesson.id, base: "Week 07 - 10-6")
        let value = try await repository.recordHandoffAudio(lesson.id, courseID: course, audio: "Week 07 - 10-6 录音 ABCD1234.m4a")
        XCTAssertEqual(value.lastReceipt?.audio, "Week 07 - 10-6 录音 ABCD1234.m4a")
        XCTAssertEqual(value.lastReceipt?.files.count, 3)
        let same = try await repository.recordHandoffAudio(lesson.id, courseID: course, audio: "Week 07 - 10-6 录音 ABCD1234.m4a")
        XCTAssertEqual(same.receipts?.count, value.receipts?.count, "同一个录音不重复登记")
    }

    func testRemovedFilesStayRemovedUnlessExportedManually() async throws {
        let lesson = try await makeLesson()
        try await handOff(lesson.id, base: "Week 07 - 10-6")
        // 外部 Agent 把转录归档走了。
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Week 07 - 10-6 课堂转录.txt"))
        try await repository.append(.line(TranscriptLine(start: 4, end: 6, original: "More.", runID: UUID())), to: lesson.id)
        let auto = try await handOff(lesson.id, base: "Week 07 - 10-6")
        XCTAssertEqual(auto.outcome.skipped, ["课堂转录.txt"])
        XCTAssertFalse(names.contains("Week 07 - 10-6 课堂转录.txt"), "自动更新不把被移走的文件放回来")
        XCTAssertTrue(try text("Week 07 - 10-6 课堂转录.vtt").contains("More."), "其余文件照常更新")
        let manual = try await handOff(lesson.id, base: "Week 07 - 10-6", manual: true)
        XCTAssertTrue(manual.outcome.skipped.isEmpty)
        XCTAssertTrue(names.contains("Week 07 - 10-6 课堂转录.txt"), "手动导出才重新生成")
    }

    func testFailureIsRecordedOncePerReasonAndClearedBySuccess() async throws {
        let lesson = try await makeLesson()
        var value = try await repository.recordHandoffFailure(lesson.id, courseID: course, folderName: "课堂转录", prefix: "", error: "文件夹需要重新选择")
        value = try await repository.recordHandoffFailure(lesson.id, courseID: course, folderName: "课堂转录", prefix: "", error: "文件夹需要重新选择")
        XCTAssertEqual(value.receipts?.count, 1, "同一原因只记一条")
        XCTAssertEqual(value.handoffStatus, .failed(course: "CS 3214", reason: "文件夹需要重新选择"))
        let done = try await handOff(lesson.id, base: "Week 07 - 10-6").lesson
        if case .delivered(let name, _, let files) = done.handoffStatus { XCTAssertEqual(name, "CS 3214"); XCTAssertEqual(files, 3) } else { XCTFail("应为已交到") }
    }

    func testFilingStatusAndRebindingBackToAPreviousCourse() async throws {
        var lesson = try await makeLesson(filed: false)
        XCTAssertEqual(lesson.handoffStatus, .unfiled)
        lesson = try await repository.append(.filed(Filing(courseID: nil, courseName: "", basis: "declined")), to: lesson.id)
        XCTAssertEqual(lesson.handoffStatus, .declined)
        lesson = try await repository.append(.filed(Filing(courseID: course, courseName: "CS 3214", basis: "asked")), to: lesson.id)
        XCTAssertEqual(lesson.handoffStatus, .waiting(course: "CS 3214"))
        try await handOff(lesson.id, base: "Week 07 - 10-6")
        // 改到别的课，再改回来：原来的固定身份还在。
        let other = UUID()
        lesson = try await repository.append(.filed(Filing(courseID: other, courseName: "CS 3724", basis: "manual")), to: lesson.id)
        XCTAssertNil(lesson.binding)
        XCTAssertEqual(lesson.handoffStatus, .waiting(course: "CS 3724"))
        lesson = try await repository.append(.filed(Filing(courseID: course, courseName: "CS 3214", basis: "manual")), to: lesson.id)
        XCTAssertEqual(lesson.binding?.prefix, "Week 07 - 10-6")
        // 重放日志后状态一致。
        let fresh = try LessonRepository(root: root.appendingPathComponent("lib"))
        let restored = try await fresh.load(lesson.id)
        XCTAssertEqual(restored, lesson)
    }

    func testLegacyLedgerIsAdoptedAsBinding() async throws {
        let lesson = try await makeLesson()
        // 0.4.x 的导出：账本按“路径|开头”识别。
        _ = try await repository.exportManaged(lesson.id, into: folder, naming: ExportNaming(), name: "Week 06 - 9-29")
        let path = folder.standardizedFileURL.path
        let missing = try await repository.adoptLegacyExport(lesson.id, folderPath: path + "-别处", courseID: course, timeZoneID: "America/New_York")
        XCTAssertNil(missing, "交到别的文件夹的旧课堂不动")
        // 不需要猜当初的名字：从旧账本里的实际文件名反推，再用哈希校验确实是这个文件夹。
        let adopted = try await repository.adoptLegacyExport(lesson.id, folderPath: path, courseID: course, timeZoneID: "America/New_York")
        XCTAssertEqual(adopted?.bindings?.first?.prefix, "Week 06 - 9-29")
        let again = try await repository.adoptLegacyExport(lesson.id, folderPath: path, courseID: course, timeZoneID: "America/New_York")
        XCTAssertNil(again, "已经认领过的不重复认领")
        // 认领后内容有更新：写回原来的文件，不另存、不加序号。
        try await repository.append(.line(TranscriptLine(start: 4, end: 6, original: "After upgrade.", runID: UUID())), to: lesson.id)
        let outcome = try await handOff(lesson.id, base: "不会用到").outcome
        XCTAssertEqual(outcome.prefix, "Week 06 - 9-29")
        XCTAssertTrue(outcome.conflicts.isEmpty)
        XCTAssertTrue(try text("Week 06 - 9-29 课堂转录.txt").contains("After upgrade."))
        XCTAssertEqual(names.count, 3)
    }
}
