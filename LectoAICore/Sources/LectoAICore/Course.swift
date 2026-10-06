import Foundation

/// 一门课上过课的一个时间段。由归到这门课的课堂累计而来，不是用户填的。
public struct Meeting: Codable, Sendable, Equatable {
    /// 1 = 周日 … 7 = 周六，按课程时区。
    public var weekday: Int
    /// 开始录音时是当天第几分钟（多次取平均）。
    public var start: Int
    /// 时长，分钟（多次取平均）。
    public var minutes: Int
    /// 这个时间段上过几次。
    public var count: Int
    /// 最近一次上课。
    public var last: Date

    public init(weekday: Int, start: Int, minutes: Int, count: Int = 1, last: Date) {
        self.weekday = weekday; self.start = start; self.minutes = minutes; self.count = count; self.last = last
    }

    /// 认课用的时间窗：开始前 25 分钟到结束前 10 分钟。
    func covers(_ minute: Int) -> Bool { minute >= start - 25 && minute <= start + max(minutes, 30) - 10 }
}

/// 课程：名称 + 课程文件夹。上课时间由归课记录自动积累。
public struct Course: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    /// 课程文件夹的安全作用域书签；失效时需要用户重新选择。
    public var folderBookmark: Data?
    public var folderName: String
    /// 上课地时区。认课与文件日期都按它计算，换了地方也不变。
    public var timeZoneID: String
    public var meetings: [Meeting]
    /// 归到这门课的课堂数。
    public var lessonCount: Int
    /// 建课时间；此前录的课堂不催归档。
    public var createdAt: Date
    /// 最近一次归课，用于界面排序。
    public var lastUsed: Date?
    /// 到点没录提醒（G1）。
    public var remind: Bool
    /// 上次用的是不是电脑声音（G1）。
    public var lastSourceSystem: Bool?
    /// 学期结束后收起：不再认课，历史课堂保留。
    public var archived: Bool

    public init(id: UUID = UUID(), name: String, folderBookmark: Data? = nil, folderName: String,
                timeZoneID: String = TimeZone.current.identifier, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.folderBookmark = folderBookmark; self.folderName = folderName
        self.timeZoneID = timeZoneID; self.createdAt = createdAt
        meetings = []; lessonCount = 0; lastUsed = nil; remind = true; lastSourceSystem = nil; archived = false
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    private enum CodingKeys: String, CodingKey {
        case id, name, folderBookmark, folderName, timeZoneID, meetings, lessonCount, createdAt, lastUsed, remind, lastSourceSystem, archived
    }

    /// 逐项宽松解码：以后新增字段时，旧版本保存的课程仍能读取。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        folderBookmark = try container.decodeIfPresent(Data.self, forKey: .folderBookmark)
        folderName = try container.decodeIfPresent(String.self, forKey: .folderName) ?? ""
        timeZoneID = try container.decodeIfPresent(String.self, forKey: .timeZoneID) ?? TimeZone.current.identifier
        meetings = try container.decodeIfPresent([Meeting].self, forKey: .meetings) ?? []
        lessonCount = try container.decodeIfPresent(Int.self, forKey: .lessonCount) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed)
        remind = try container.decodeIfPresent(Bool.self, forKey: .remind) ?? true
        lastSourceSystem = try container.decodeIfPresent(Bool.self, forKey: .lastSourceSystem)
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }

    /// 这个时刻在课程时区里是星期几、当天第几分钟。
    func clock(_ date: Date) -> (weekday: Int, minute: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        return (parts.weekday ?? 1, (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    /// 设置页里显示的上课时间，如“周二 周四 09:30 左右”。时刻相近的日子合并显示。
    public var meetingSummary: String {
        guard !meetings.isEmpty else { return "" }
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        var groups: [(start: Int, days: [Int])] = []
        for meeting in meetings.sorted(by: { ($0.start, $0.weekday) < ($1.start, $1.weekday) }) {
            if let index = groups.firstIndex(where: { abs($0.start - meeting.start) <= 25 }) {
                if !groups[index].days.contains(meeting.weekday) { groups[index].days.append(meeting.weekday) }
            } else { groups.append((meeting.start, [meeting.weekday])) }
        }
        return groups.map { group in
            // 周一排在最前，周日在最后。
            let days = group.days.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { names[max(0, min(6, $0 - 1))] }.joined(separator: " ")
            return "\(days) \(Course.clockText(group.start)) 左右"
        }.joined(separator: "，")
    }

    /// 把时刻取整到 5 分钟显示：记录的是开始录音的时刻，本来就不精确。
    public static func clockText(_ minute: Int) -> String {
        let rounded = Int((Double(minute) / 5).rounded()) * 5
        return String(format: "%02d:%02d", rounded / 60 % 24, rounded % 60)
    }
}

/// 全部课程，以及“按以往上课时间认课”的规则。
public struct CourseBook: Codable, Sendable, Equatable {
    /// `known`：靠得住，下课直接交；`guess`：只是建议，要用户点一下确认。
    public enum Confidence: String, Sendable, Equatable { case known, guess }

    public struct Suggestion: Sendable, Equatable {
        public var course: Course
        public var confidence: Confidence
    }

    public var courses: [Course] = []

    public init(courses: [Course] = []) { self.courses = courses }

    private enum CodingKeys: String, CodingKey { case courses }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        courses = try container.decodeIfPresent([Course].self, forKey: .courses) ?? []
    }

    public func course(_ id: UUID?) -> Course? { id.flatMap { id in courses.first { $0.id == id } } }

    /// 未收起的课程，最近用过的排前面。
    public var active: [Course] {
        courses.filter { !$0.archived }.sorted { ($0.lastUsed ?? $0.createdAt) > ($1.lastUsed ?? $1.createdAt) }
    }

    /// 上课时间记录多久没更新就不再当作靠得住（5 周）。
    static let freshness: TimeInterval = 35 * 86400

    /// 按以往上课时间认课。两门课同时吻合时不猜。
    public func suggest(at date: Date) -> Suggestion? {
        var matched: [Suggestion] = []
        var sameClock: [Course] = []
        for course in courses where !course.archived && !course.meetings.isEmpty {
            let now = course.clock(date)
            if let meeting = course.meetings.first(where: { $0.weekday == now.weekday && $0.covers(now.minute) }) {
                let fresh = date.timeIntervalSince(meeting.last) < Self.freshness
                // 这个时间段上过至少两次；或只上过一次，但这门课在别的日子的同一时刻也上过。
                let corroborated = meeting.count >= 2
                    || course.meetings.contains { $0.weekday != meeting.weekday && abs($0.start - meeting.start) <= 25 }
                matched.append(Suggestion(course: course, confidence: fresh && corroborated ? .known : .guess))
            } else if course.meetings.contains(where: { abs($0.start - now.minute) <= 25 }) {
                sameClock.append(course)
            }
        }
        if matched.count == 1 { return matched[0] }
        if matched.isEmpty, sameClock.count == 1 { return Suggestion(course: sameClock[0], confidence: .guess) }
        return nil
    }

    /// 不到 10 分钟的课堂不记上课时间（试录、误触）。
    static let shortestMeeting = 10

    /// 课堂归到一门课：累计上课时间。`start` 为开始录音的时刻，`minutes` 为时长；`counted` 为 false 时只计数不记时间（导入的录音）。
    public mutating func learn(courseID: UUID, start: Date, minutes: Int, counted: Bool = true, usedAt: Date = Date()) {
        guard let index = courses.firstIndex(where: { $0.id == courseID }) else { return }
        courses[index].lessonCount += 1
        courses[index].lastUsed = max(courses[index].lastUsed ?? .distantPast, usedAt)
        guard counted, minutes >= Self.shortestMeeting else { return }
        let clock = courses[index].clock(start)
        if let slot = courses[index].meetings.firstIndex(where: { $0.weekday == clock.weekday && Self.same($0, clock.minute) }) {
            var meeting = courses[index].meetings[slot]
            // 开始时刻相差不大才更新平均值；迟到很久才开始录的那次只计数，不把时间带偏。
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = courses[index].timeZone
            // 同一天的第二条记录（中断后重开、同一次课拆成两堂）不算又上了一次，否则一次课就能凑够“上过两次”。
            if !calendar.isDate(start, inSameDayAs: meeting.last) {
                if abs(clock.minute - meeting.start) <= 15 {
                    meeting.start = (meeting.start * meeting.count + clock.minute) / (meeting.count + 1)
                    meeting.minutes = (meeting.minutes * meeting.count + minutes) / (meeting.count + 1)
                }
                meeting.count += 1
            }
            meeting.last = max(meeting.last, start)
            courses[index].meetings[slot] = meeting
        } else {
            courses[index].meetings.append(Meeting(weekday: clock.weekday, start: clock.minute, minutes: minutes, last: start))
        }
    }

    /// 由全部课堂重新统计各门课的上课时间与课堂数：只算已经结束、归到该课的课堂。
    /// 应用层在课堂列表变化后调用它，而不是逐次加减，这样改归、删除课堂之后不会留下对不上的旧数据。
    public mutating func relearn(from lessons: [Lesson]) {
        for index in courses.indices { courses[index].meetings = []; courses[index].lessonCount = 0 }
        for lesson in lessons.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let filing = lesson.filing, let id = filing.courseID, lesson.phase == .completed || lesson.phase == .interrupted else { continue }
            learn(courseID: id, start: lesson.createdAt, minutes: Int(lesson.duration / 60), counted: lesson.source != Lesson.importedSource, usedAt: filing.at)
        }
    }

    /// 课堂从一门课移走（改到别的课、移到废纸篓）：减掉它的那一次。参数与当初 `learn` 时相同。
    public mutating func forget(courseID: UUID, start: Date, minutes: Int, counted: Bool = true) {
        guard let index = courses.firstIndex(where: { $0.id == courseID }) else { return }
        courses[index].lessonCount = max(0, courses[index].lessonCount - 1)
        guard counted, minutes >= Self.shortestMeeting else { return }
        let clock = courses[index].clock(start)
        guard let slot = courses[index].meetings.firstIndex(where: { $0.weekday == clock.weekday && Self.same($0, clock.minute) }) else { return }
        courses[index].meetings[slot].count -= 1
        if courses[index].meetings[slot].count <= 0 { courses[index].meetings.remove(at: slot) }
    }

    /// 同一个时间段：开始时刻相差 30 分钟以内，或落在这个时间段里（迟到开始录）。
    private static func same(_ meeting: Meeting, _ minute: Int) -> Bool {
        abs(minute - meeting.start) <= 30 || (minute > meeting.start && meeting.covers(minute))
    }

    /// 这些文件夹名说明不了是哪门课，取名时往上一级找。
    private static let genericNames: Set<String> = ["raw", "课堂转录", "转录", "转写", "录音", "资料", "课堂", "笔记",
                                                    "transcripts", "transcript", "lectures", "lecture", "notes", "recordings", "audio"]

    /// 从文件夹路径推断课程名：由近到远找像课程代码的一段（如 CS3214、CS 3214），找不到就用第一个不是通用名的文件夹名。
    public static func suggestedName(for folder: URL) -> String {
        let parts = Array(folder.standardizedFileURL.pathComponents.filter { $0 != "/" }.reversed().prefix(5))
        guard let leaf = parts.first else { return "" }
        let code = /^([A-Za-z]{2,6})[ _-]?[0-9]{3,4}[A-Za-z]?$/
        // “Fall2026”这类学期文件夹长得像课程代码，排除掉。
        let terms: Set<String> = ["fall", "spring", "summer", "winter", "autumn", "term", "sem", "year"]
        if let match = parts.first(where: { part in
            guard let found = try? code.wholeMatch(in: part) else { return false }
            return !terms.contains(found.1.lowercased())
        }) { return match }
        return parts.first { !genericNames.contains($0.lowercased()) } ?? leaf
    }
}
