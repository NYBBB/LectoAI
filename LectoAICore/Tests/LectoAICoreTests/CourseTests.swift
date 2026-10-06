import XCTest
@testable import LectoAICore

/// 课程：按以往上课时间认课、累计上课时间、从路径推断课程名、命名的时区与默认标题。
final class CourseTests: XCTestCase {
    private let eastern = "America/New_York"

    /// 课程时区里的某个时刻。2026-10-06 是周二。
    private func date(_ day: Int, _ hour: Int, _ minute: Int, zone: String? = nil) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone ?? eastern)!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func book(_ names: String...) -> CourseBook {
        CourseBook(courses: names.map { Course(name: $0, folderName: "课堂转录", timeZoneID: eastern) })
    }

    func testFirstLessonOnlySuggestsAndRegularPatternBecomesKnown() {
        var courses = book("CS 3214")
        let id = courses.courses[0].id
        XCTAssertNil(courses.suggest(at: date(6, 9, 28)), "没有上课时间记录时不猜")

        // 周二第一堂：下一个周二只是建议（只上过一次，没有旁证）。
        courses.learn(courseID: id, start: date(6, 9, 31), minutes: 74)
        XCTAssertEqual(courses.suggest(at: date(13, 9, 29))?.confidence, .guess)
        // 周四同一时刻：星期几对不上，只对上时刻，也只是建议。
        XCTAssertEqual(courses.suggest(at: date(8, 9, 33))?.confidence, .guess)

        // 周四也上过一次之后：周二有了旁证，自动认出。
        courses.learn(courseID: id, start: date(8, 9, 33), minutes: 75)
        XCTAssertEqual(courses.suggest(at: date(13, 9, 29))?.confidence, .known)
        XCTAssertEqual(courses.suggest(at: date(13, 9, 29))?.course.id, id)
        // 迟到 40 分钟才开始录，仍在这堂课的时间里。
        XCTAssertEqual(courses.suggest(at: date(13, 10, 12))?.confidence, .known)
        // 下课前 10 分钟之后、别的时间都不认。
        XCTAssertNil(courses.suggest(at: date(13, 10, 40)))
        XCTAssertNil(courses.suggest(at: date(13, 14, 0)))
        XCTAssertEqual(courses.courses[0].meetingSummary, "周二 周四 09:30 左右")
    }

    func testTwoCoursesAtTheSameTimeAreNotGuessed() {
        var courses = book("CS 3214", "CS 3724")
        let first = courses.courses[0].id, second = courses.courses[1].id
        for day in [6, 13] {
            courses.learn(courseID: first, start: date(day, 9, 30), minutes: 75)
            courses.learn(courseID: second, start: date(day, 9, 35), minutes: 75)
        }
        XCTAssertNil(courses.suggest(at: date(20, 9, 30)), "两门课都吻合时不猜")
        // 相邻的两门课（中间隔 15 分钟）各认各的。
        var adjacent = book("A", "B")
        let a = adjacent.courses[0].id, b = adjacent.courses[1].id
        for day in [6, 13] {
            adjacent.learn(courseID: a, start: date(day, 9, 30), minutes: 75)
            adjacent.learn(courseID: b, start: date(day, 11, 0), minutes: 75)
        }
        XCTAssertEqual(adjacent.suggest(at: date(20, 10, 40))?.course.id, b, "提前 20 分钟到下一堂课")
        XCTAssertEqual(adjacent.suggest(at: date(20, 9, 20))?.course.id, a)
    }

    func testLearnMergesNearbyStartsAndForgetRemoves() {
        var courses = book("CS 3214")
        let id = courses.courses[0].id
        courses.learn(courseID: id, start: date(6, 9, 30), minutes: 75)
        courses.learn(courseID: id, start: date(13, 9, 36), minutes: 71)
        courses.learn(courseID: id, start: date(20, 10, 15), minutes: 30)   // 迟到很久：只计数，不带偏时间
        XCTAssertEqual(courses.courses[0].meetings.count, 1)
        XCTAssertEqual(courses.courses[0].meetings[0].count, 3)
        XCTAssertEqual(courses.courses[0].meetings[0].start, 9 * 60 + 33)
        XCTAssertEqual(courses.courses[0].lessonCount, 3)

        // 同一天中断后重开的第二条记录：不算又上了一次。
        courses.learn(courseID: id, start: date(20, 10, 25), minutes: 20)
        XCTAssertEqual(courses.courses[0].meetings[0].count, 3)
        XCTAssertEqual(courses.courses[0].lessonCount, 4)
        courses.courses[0].lessonCount = 3

        courses.learn(courseID: id, start: date(7, 15, 0), minutes: 4)       // 试录：不记时间
        XCTAssertEqual(courses.courses[0].meetings.count, 1)
        courses.learn(courseID: id, start: date(7, 15, 0), minutes: 60, counted: false)   // 导入的录音：不记时间
        XCTAssertEqual(courses.courses[0].meetings.count, 1)
        XCTAssertEqual(courses.courses[0].lessonCount, 5)

        courses.forget(courseID: id, start: date(20, 10, 15), minutes: 30)
        courses.forget(courseID: id, start: date(13, 9, 36), minutes: 71)
        XCTAssertEqual(courses.courses[0].meetings[0].count, 1)
        courses.forget(courseID: id, start: date(6, 9, 30), minutes: 75)
        XCTAssertTrue(courses.courses[0].meetings.isEmpty)
        XCTAssertEqual(courses.courses[0].lessonCount, 2)
    }

    func testRelearnRebuildsFromFiledFinishedLessons() {
        var courses = book("CS 3214", "CS 3724")
        let first = courses.courses[0].id, second = courses.courses[1].id
        func lesson(_ day: Int, _ hour: Int, minutes: Double, course: UUID?, phase: LessonPhase = .completed, source: String = "麦克风") -> Lesson {
            var value = Lesson(title: "课堂", source: source)
            value.createdAt = date(day, hour, 30); value.duration = minutes * 60; value.phase = phase
            if let course { value.filing = Filing(courseID: course, courseName: "", basis: "asked", at: value.createdAt) }
            return value
        }
        let lessons = [lesson(6, 9, minutes: 75, course: first), lesson(8, 9, minutes: 74, course: first), lesson(13, 9, minutes: 75, course: first),
                       lesson(6, 14, minutes: 50, course: second), lesson(7, 14, minutes: 3, course: second),
                       lesson(8, 14, minutes: 50, course: second, source: Lesson.importedSource),
                       lesson(13, 14, minutes: 40, course: second, phase: .recording), lesson(9, 9, minutes: 60, course: nil)]
        courses.courses[0].meetings = [Meeting(weekday: 1, start: 0, minutes: 10, last: date(1, 0, 0))]   // 旧数据会被重算覆盖
        courses.relearn(from: lessons)
        XCTAssertEqual(courses.courses[0].lessonCount, 3)
        XCTAssertEqual(courses.courses[0].meetingSummary, "周二 周四 09:30 左右")
        XCTAssertEqual(courses.courses[0].meetings.first { $0.weekday == 3 }?.count, 2)
        XCTAssertEqual(courses.courses[1].lessonCount, 3, "太短的和导入的只计数；还在录的不算")
        XCTAssertEqual(courses.courses[1].meetings.count, 1)
        XCTAssertEqual(courses.courses[1].lastUsed, date(8, 14, 30))
        var again = courses; again.relearn(from: lessons)
        XCTAssertEqual(again, courses, "重复统计结果不变")
    }

    func testStaleMeetingsAndArchivedCoursesAreNotKnown() {
        var courses = book("CS 3214")
        let id = courses.courses[0].id
        courses.learn(courseID: id, start: date(6, 9, 30), minutes: 75)
        courses.learn(courseID: id, start: date(13, 9, 30), minutes: 75)
        XCTAssertEqual(courses.suggest(at: date(20, 9, 30))?.confidence, .known)
        // 超过 5 周没上（新学期）：降为建议。
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: eastern)!
        let later = calendar.date(byAdding: .day, value: 42, to: date(13, 9, 30))!   // 按日历加，避开夏令时切换
        XCTAssertEqual(courses.suggest(at: later)?.confidence, .guess)
        courses.courses[0].archived = true
        XCTAssertNil(courses.suggest(at: date(20, 9, 30)))
        XCTAssertTrue(courses.active.isEmpty)
    }

    func testCourseTimeZoneIsUsedNotTheSystemOne() {
        var courses = book("CS 3214")
        let id = courses.courses[0].id
        courses.learn(courseID: id, start: date(6, 9, 30), minutes: 75)
        courses.learn(courseID: id, start: date(13, 9, 30), minutes: 75)
        // 同一个绝对时刻，用东八区的钟表表达：仍按课程的美东时间认课（周二 09:30 = 北京周二 21:30）。
        let sameInstant = date(20, 21, 30, zone: "Asia/Shanghai")
        XCTAssertEqual(sameInstant, date(20, 9, 30))
        XCTAssertEqual(courses.suggest(at: sameInstant)?.confidence, .known)
        XCTAssertNil(courses.suggest(at: date(20, 9, 30, zone: "Asia/Shanghai")), "北京的周二 09:30 是美东周一晚上")
    }

    func testSuggestedNameFromFolderPath() {
        XCTAssertEqual(CourseBook.suggestedName(for: URL(fileURLWithPath: "/Users/a/课程/2026Fall/CS3214/raw/课堂转录")), "CS3214")
        XCTAssertEqual(CourseBook.suggestedName(for: URL(fileURLWithPath: "/Users/a/Courses/MATH 2114/notes")), "MATH 2114")
        XCTAssertEqual(CourseBook.suggestedName(for: URL(fileURLWithPath: "/Users/a/学校/操作系统/课堂转录")), "操作系统")
        XCTAssertEqual(CourseBook.suggestedName(for: URL(fileURLWithPath: "/Users/a/Desktop/线性代数")), "线性代数")
        XCTAssertEqual(CourseBook.suggestedName(for: URL(fileURLWithPath: "/Users/a/Fall2026/操作系统/课堂转录")), "操作系统", "学期文件夹不是课程代码")
    }

    func testCourseBookDecodesLeniently() throws {
        let id = UUID()
        let json = #"{"courses":[{"id":"\#(id.uuidString)","name":"CS 3214"}]}"#
        let value = try JSONDecoder().decode(CourseBook.self, from: Data(json.utf8))
        XCTAssertEqual(value.courses.first?.id, id)
        XCTAssertEqual(value.courses.first?.remind, true)
        XCTAssertEqual(value.courses.first?.meetings, [])
        let round = try JSONDecoder().decode(CourseBook.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(round, value)
    }

    func testPrefixUsesGivenTimeZoneRecordedDateAndTitleOverride() throws {
        var lesson = Lesson(title: "Oct 6, 2026 at 9:31 PM", source: "麦克风")
        // 美东 10 月 6 日 21:31 = 东八区 10 月 7 日 09:31。
        lesson.createdAt = date(6, 21, 31)
        lesson.timeZoneID = "Asia/Shanghai"
        let naming = ExportNaming(template: "{date} {title}")
        XCTAssertEqual(try naming.prefix(for: lesson), "2026-10-07 Oct 6, 2026 at 9-31 PM", "没归课时按这堂课创建时的时区")
        XCTAssertEqual(try naming.prefix(for: lesson, timeZone: TimeZone(identifier: eastern), title: "CS 3214"), "2026-10-06 CS 3214")
        // 学期第一周从 8 月 24 日（周一）起：10 月 6 日是第 7 周。
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: eastern)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 8, day: 24))!
        let weekly = ExportNaming(template: "Week {week} - {M}-{D}", semesterStart: start)
        XCTAssertEqual(try weekly.prefix(for: lesson, timeZone: TimeZone(identifier: eastern)), "Week 07 - 10-6")
        // 导入的录音：用录制日期，不用导入日期。
        lesson.recordedAt = date(1, 10, 0)
        XCTAssertEqual(try weekly.prefix(for: lesson, timeZone: TimeZone(identifier: eastern)), "Week 06 - 10-1")
    }
}
