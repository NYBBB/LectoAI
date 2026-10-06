import XCTest
@testable import LectoAICore

final class LectureDigestTests: XCTestCase {
    private func lesson(lines: [TranscriptLine]) -> Lesson {
        var value = Lesson(title: "算法", source: "麦克风")
        for line in lines { LessonReducer.apply(.line(line), to: &value) }
        return value
    }

    func testContinueUpdatesSameSectionAndNewStartsAnother() throws {
        let run = UUID()
        let a = TranscriptLine(start: 0, end: 4, original: "A greedy algorithm picks the local best.", runID: run)
        let b = TranscriptLine(start: 65, end: 69, original: "We prove it with an exchange argument.", runID: run)
        var value = lesson(lines: [a])
        let first = try XCTUnwrap(LectureDigest.request(for: value))
        XCTAssertTrue(first.user.contains("【当前小节】无"))
        XCTAssertTrue(first.user.contains("[00:00] A greedy"), "原文用课堂时间标注")
        XCTAssertFalse(first.user.contains(a.id.uuidString), "不再把 UUID 发给模型")
        let json1 = #"{"lessonTitle":"贪心算法入门","focus":{"topic":"贪心算法","phase":"definition","hint":"记住定义"},"action":"new","section":{"title":"贪心算法","summary":"每步选局部最优。","points":[{"text":"贪心每步选当前最优","kind":"concept","sources":["00:00"]}]}}"#
        let update1 = try LectureDigest.parse(json1, request: first, now: 4)
        XCTAssertTrue(update1.startsNewSection)
        XCTAssertEqual(update1.lessonTitle, "贪心算法入门")
        XCTAssertEqual(update1.section.points.first?.sources, [a.id])
        LessonReducer.apply(.digestSection(update1.section), to: &value)
        LessonReducer.apply(.focus(update1.focus), to: &value)

        // 只有新增原文进入下一次请求，当前小节随请求一起给出（出处写成时间）。
        LessonReducer.apply(.line(b), to: &value)
        let second = try XCTUnwrap(LectureDigest.request(for: value))
        XCTAssertFalse(second.user.contains(a.original))
        XCTAssertTrue(second.user.contains("[01:05] We prove"))
        XCTAssertTrue(second.user.contains("依据：00:00"))
        // 模型用 UUID 前 8 位、写错的出处都不会让整次结果作废。
        let short = String(b.id.uuidString.prefix(8))
        let json2 = #"```json\#n<think>先想一想</think>{"focus":{"topic":"交换论证","phase":"derivation","hint":"跟紧证明"},"action":"continue","section":{"title":"贪心与交换论证","summary":"贪心需要证明。","points":[{"text":"贪心每步选当前最优","kind":"concept","sources":["00:00"]},{"text":"用交换论证（exchange argument）证明","kind":"weird","sources":["\#(short)","99:99"]}]}}\#n```"#
        let update2 = try LectureDigest.parse(json2, request: second, now: 69)
        XCTAssertFalse(update2.startsNewSection)
        XCTAssertNil(update2.lessonTitle, "没给标题时不建议改名")
        XCTAssertEqual(update2.section.id, update1.section.id)
        XCTAssertEqual(update2.section.start, 0)
        XCTAssertEqual(update2.section.end, 69)
        XCTAssertEqual(update2.section.points.last?.kind, "key")
        XCTAssertEqual(update2.section.points.last?.sources, [b.id])
        LessonReducer.apply(.digestSection(update2.section), to: &value)
        XCTAssertEqual(value.digest?.count, 1)
        XCTAssertNil(LectureDigest.request(for: value))
        XCTAssertEqual(LessonText.files(for: value)["课堂纪要.md"]?.contains("交换论证（exchange argument）"), true)
    }

    func testRejectsBrokenJSONButKeepsPointsWithBadSources() throws {
        let line = TranscriptLine(start: 0, end: 2, original: "Hello.", runID: UUID())
        let request = try XCTUnwrap(LectureDigest.request(for: lesson(lines: [line])))
        let bad = #"{"focus":{"topic":"t","phase":"qa","hint":""},"action":"new","section":{"title":"t","summary":"","points":[{"text":"x","kind":"key","sources":["\#(UUID())"]}]}}"#
        let update = try LectureDigest.parse(bad, request: request, now: 2)
        XCTAssertEqual(update.section.points.first?.sources, [])
        XCTAssertThrowsError(try LectureDigest.parse("not json", request: request, now: 2))
    }

    func testToleratesCommonFormatDeviations() throws {
        let line = TranscriptLine(start: 607, end: 610, original: "Multi-class uses frequencies.", runID: UUID())
        let request = try XCTUnwrap(LectureDigest.request(for: lesson(lines: [line])))
        // 没有 focus、出处写成单个字符串、末尾多余逗号、要点超过 10 条、概述过长。
        let points = (1...14).map { #"{"text":"要点\#($0)","sources":"10:07",}"# }.joined(separator: ",")
        let output = #"好的：```json {"action":"new","section":{"title":"多分类","summary":"\#(String(repeating: "长", count: 500))","points":[\#(points),]},} ```"#
        let update = try LectureDigest.parse(output, request: request, now: 610)
        XCTAssertEqual(update.section.points.count, 10)
        XCTAssertEqual(update.section.points[0].sources, [line.id])
        XCTAssertEqual(update.section.summary.count, 400)
        XCTAssertEqual(update.focus.topic, "多分类", "缺少此刻话题时用小节标题")
        XCTAssertThrowsError(try LectureDigest.parse(#"{"section":{"title":""}}"#, request: request, now: 610))
    }

    func testLineReferencesAcceptTimesUUIDsAndPrefixes() {
        let run = UUID()
        let a = TranscriptLine(start: 723.4, end: 726, original: "a", runID: run)
        let b = TranscriptLine(start: 4150.2, end: 4152, original: "b", runID: run)
        let lines = [a, b]
        XCTAssertEqual(LineRef.resolve("12:03", in: lines)?.id, a.id)
        XCTAssertEqual(LineRef.resolve("12:05", in: lines)?.id, a.id, "允许几秒误差")
        XCTAssertNil(LineRef.resolve("20:00", in: lines))
        XCTAssertEqual(LineRef.resolve("69:10", in: lines)?.id, b.id, "超过一小时仍按分:秒")
        XCTAssertEqual(LineRef.resolve("1:09:10", in: lines)?.id, b.id)
        XCTAssertEqual(LineRef.resolve(String(b.id.uuidString.prefix(8)).lowercased(), in: lines)?.id, b.id)
        XCTAssertEqual(LineRef.citations(in: "见 [12:03][69:10]，另见 [12:03, 69:10] 与 [链接文字](https://x)", lines: lines), [a.id, b.id])
        let rendered = LineRef.render("A [12:03] B [链接文字](https://x) C [\(UUID().uuidString)]", lines: lines) { _, time in "<\(time)>" }
        XCTAssertEqual(rendered, "A <12:03> B [链接文字](https://x) C [来源已更新]")
        // 时间段引用：链接到开头那句，标签保留原样。
        XCTAssertEqual(LineRef.render("见 [12:03–69:10]", lines: lines) { _, time in "<\(time)>" }, "见 <12:03–69:10>")
        XCTAssertEqual(LineRef.citations(in: "[12:03-12:05]", lines: lines), [a.id])
        XCTAssertEqual(LineRef.render("组 [12:03][69:10]。", lines: lines) { _, time in time }, "组 12:03、69:10。", "相邻引用之间加顿号")
    }

    func testOldAnswersWithoutMediaTimeStillDecode() throws {
        let answer = LessonAnswer(question: "q", answer: "a", citations: [])
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(answer)) as! [String: Any]
        object.removeValue(forKey: "mediaTime")
        XCTAssertNil(try JSONDecoder().decode(LessonAnswer.self, from: JSONSerialization.data(withJSONObject: object)).mediaTime)
    }
}
