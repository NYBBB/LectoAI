#if DEBUG
import AppKit
import Foundation
import LectoAICore

/// 仅 Debug：在隔离的临时资料库里生成演示课堂，用于界面自查与截图；不录音、不调用模型、不写真实资料。
/// 参数：--demo（上课中）、--demo-review（回看）、--demo-start（开始页）；--demo-animate 让上课中的字幕持续推进。
/// --demo-courses 加上几门演示课程与上课时间记录（只在内存里）；--demo-finish <状态> 让回看的那堂课呈现某种下课横幅：
/// delivered / settling / ask / filed / failed / conflict / working / new（就地新建课程的确认卡）。--demo-export-open 打开导出面板。
@MainActor
enum DemoClassroom {
    static var requested: Bool {
        ProcessInfo.processInfo.arguments.contains { ["--demo", "--demo-review", "--demo-start"].contains($0) }
    }

    private static let script: [(String, String)] = [
        ("Okay, let's pick up where we left off with process creation.", "好，我们接着上次讲进程的创建。"),
        ("Last time we saw that fork gives you two nearly identical processes.", "上次我们看到，fork 会给你两个几乎一模一样的进程。"),
        ("The child gets a copy of the parent's address space.", "子进程会得到父进程地址空间的一份副本。"),
        ("But most of the time, the child doesn't want to keep running the same program.", "但大多数时候，子进程并不想继续运行同一个程序。"),
        ("That's where exec comes in.", "这就是 exec 登场的地方。"),
        ("Exec replaces the current process image with a new program.", "exec 会用一个新程序替换当前的进程映像。"),
        ("The key idea is that exec never returns on success.", "关键在于，exec 成功时根本不会返回。"),
        ("So anything after it only runs if the call fails.", "所以它后面的代码只有在调用失败时才会执行。"),
        ("That's why you always see an error check right after exec.", "这就是为什么 exec 之后总会紧跟一个错误检查。"),
        ("Now, what happens to open file descriptors?", "那么，已经打开的文件描述符会怎样？"),
        ("They stay open across exec, unless you set close-on-exec.", "除非设置了 close-on-exec，否则它们在 exec 之后仍然保持打开。"),
        ("This is exactly how the shell sets up redirection.", "shell 正是这样实现重定向的。"),
        ("It forks, the child rearranges its file descriptors, and then it calls exec.", "它先 fork，子进程重新安排自己的文件描述符，然后再调用 exec。"),
        ("And the parent waits for the child with waitpid.", "父进程则用 waitpid 等待子进程。"),
        ("If the parent never waits, the child becomes a zombie.", "如果父进程一直不等待，子进程就会变成僵尸进程。"),
        ("A zombie has finished running, but its exit status hasn't been collected.", "僵尸进程已经运行结束，但它的退出状态还没有被回收。"),
    ]

    private static let polished = [
        "好，我们接着上次讲进程的创建。上次我们看到，fork 会产生两个几乎完全相同的进程，子进程得到父进程地址空间的一份副本。但大多数时候，子进程并不想继续运行同一个程序。",
        "这时就要用到 exec：它用一个新程序替换当前的进程映像。关键在于，exec 一旦成功就不会返回，所以它后面的代码只会在调用失败时执行——这也是为什么 exec 之后总是紧跟着错误检查。",
    ]

    static func install(into model: AppModel, repository: LessonRepository) async {
        do {
            let arguments = ProcessInfo.processInfo.arguments
            let withCourses = arguments.contains("--demo-courses")
            let finish = arguments.firstIndex(of: "--demo-finish").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            // 有课程时标题只写课题，课程名显示在副标题里；下课横幅的演示用一堂 75 分钟的课。
            var yesterday = try await pastLesson(repository, title: withCourses ? "信号与管道" : "CS 3214 · 信号与管道", daysAgo: 1,
                                                 duration: finish == nil ? 64 : 4500)
            let math = try await pastLesson(repository, title: withCourses ? "特征值" : "MATH 2114 · 特征值", daysAgo: 3)
            // 开始页“最近的纪要”：给较早的一堂课一段纪要（昨天那堂保持未整理，用于回看的整理按钮）。
            if let first = math.lines.first {
                _ = try await repository.append(.digestSection(DigestSection(start: 0, end: 40, title: "特征值与特征向量",
                    summary: "Av = λv 定义特征值；通过 det(A − λI) = 0 求特征值，再解齐次方程得到特征向量。",
                    points: [DigestPoint(text: "作业 5 下周三截止，含第 3 节全部习题", kind: "notice", sources: [first.id])])), to: math.id)
            }
            if withCourses {
                yesterday = try await installCourses(model, repository: repository, yesterday: yesterday, math: math, finish: finish)
            }
            if let index = arguments.firstIndex(of: "--demo-settings"), index + 1 < arguments.count {
                model.settingsRequest = SettingsTab(rawValue: arguments[index + 1])
                Task { @MainActor in
                    // 截图自查：设置窗口同样置前，避免被台前调度收起。
                    try? await Task.sleep(for: .seconds(1.5))
                    for window in NSApp.windows where window.identifier?.rawValue.contains("Settings") == true { window.level = .floating }
                }
            }
            if arguments.contains("--demo-start") {
                await model.refreshHistory()
            } else if arguments.contains("--demo-review") {
                await model.refreshHistory()
                model.open(yesterday)
                model.justFinishedID = yesterday.id
                if finish == "working" { model.handingOff = [yesterday.id] }
                if finish == "settling" { model.translating = true }
                if finish == "new" {
                    model.courseDraft = CourseDraft(name: "CS3214", folderName: "课堂转录", trail: "CS3214 › raw › 课堂转录", bookmark: Data(),
                                                    lessonID: yesterday.id, meeting: "周二 09:30 左右")
                }
                if arguments.contains("--demo-export-open") { model.presentExport() }
            } else {
                let live = try await liveLesson(repository)
                await model.refreshHistory()
                model.open(live)
                model.elapsed = 13 * 60 + 12
                model.level = 0.55
                model.partialStart = 790
                model.partial = "And the parent waits for the child with"
                if arguments.contains("--demo-animate") { animate(model, repository: repository, lessonID: live.id) }
            }
        } catch { model.message = "演示数据生成失败：\(error.localizedDescription)" }
    }

    /// 上课中：两段已完成（一段整段译文、一段逐句草稿），最后一段进行中且有一句尚未翻译。
    private static func liveLesson(_ repository: LessonRepository) async throws -> Lesson {
        var value = try await repository.create(title: "CS 3214 · 进程与 exec", source: "麦克风")
        let run = UUID()
        let starts: [Double] = [705, 709, 713, 717, 731, 735, 739, 743, 747, 759, 763, 767, 771]
        var lines: [TranscriptLine] = []
        for (index, start) in starts.enumerated() {
            var line = TranscriptLine(start: start, end: start + 3.4, original: script[index].0, runID: run)
            line.engine = "Apple SpeechTranscriber"
            lines.append(line)
            value = try await repository.append(.line(line), to: value.id)
            if index < 12 { value = try await repository.append(.translation(line.id, 1, script[index].1), to: value.id) }
        }
        let groups = ParagraphAssembler.groups(for: value)
        if let first = groups.first {
            value = try await repository.append(.paragraph(.init(id: first.id, fingerprint: first.fingerprint, text: polished[0])), to: value.id)
        }
        var confused = LessonNote(line: lines[6], mediaTime: 741)
        confused.mark = .confused
        value = try await repository.append(.note(confused), to: value.id)
        let note = LessonNote(line: lines[10], mediaTime: 766, text: "和 fork 的区别：exec 不创建新进程，只换掉程序")
        value = try await repository.append(.note(note), to: value.id)
        value = try await repository.append(.chunk(.init(file: "demo.m4a", start: 0, duration: 792)), to: value.id)
        let sections = [
            DigestSection(start: 705, end: 721, title: "fork 回顾", summary: "上节课的 fork 会得到两个几乎相同的进程，子进程复制父进程的地址空间。",
                          points: [DigestPoint(text: "fork 之后父子进程几乎完全相同", kind: "concept", sources: [lines[1].id]),
                                   DigestPoint(text: "子进程得到父进程地址空间（address space）的副本", kind: "key", sources: [lines[2].id])]),
            DigestSection(start: 731, end: 774, title: "exec 与重定向", summary: "exec 用新程序替换当前进程映像；成功时不返回。shell 利用文件描述符跨 exec 保持打开来实现重定向。",
                          points: [DigestPoint(text: "exec 用新程序替换进程映像（process image）", kind: "concept", sources: [lines[5].id]),
                                   DigestPoint(text: "exec 成功不返回，其后的代码只在失败时执行", kind: "key", sources: [lines[6].id, lines[7].id]),
                                   DigestPoint(text: "未设 close-on-exec 时文件描述符跨 exec 保持打开", kind: "key", sources: [lines[10].id]),
                                   DigestPoint(text: "shell：fork → 子进程调整文件描述符 → exec", kind: "example", sources: [lines[11].id, lines[12].id]),
                                   DigestPoint(text: "期中会考 fork/exec 的区别", kind: "notice", sources: [lines[9].id])]),
        ]
        for section in sections { value = try await repository.append(.digestSection(section), to: value.id) }
        let article = [
            ArticleParagraph(start: 705, end: 721, text: "老师先回顾了上节课的 fork：调用之后会得到两个几乎完全相同的进程，子进程拿到父进程地址空间（address space）的一份副本。但多数情况下，子进程并不想继续运行同一个程序。"),
            ArticleParagraph(start: 731, end: 750, text: "这就引出了 exec：它用一个新程序替换当前的进程映像（process image）。关键在于 exec 成功时不会返回，所以紧跟在它后面的代码只会在调用失败时执行，这也是 exec 之后总要做错误检查的原因。"),
            ArticleParagraph(start: 759, end: 774, text: "已经打开的文件描述符在 exec 之后仍然保持打开，除非设置了 close-on-exec。shell 正是利用这一点实现重定向：先 fork，子进程调整好自己的文件描述符，再调用 exec。"),
        ]
        for paragraph in article { value = try await repository.append(.articleParagraph(paragraph), to: value.id) }
        value = try await repository.append(.focus(LiveFocus(topic: "exec 与重定向", phase: "derivation", hint: "在讲 shell 重定向的步骤，注意顺序", at: 774)), to: value.id)
        value = try await repository.append(.answer(.init(question: "为什么 exec 之后还要检查错误？",
                                                           answer: "因为 exec 成功时会把当前程序整个换掉，**不会再回到原来的代码** [\(lines[6].id.uuidString)]。所以只要执行到了 exec 后面的那一行，就说明 exec 失败了，需要处理错误 [\(lines[7].id.uuidString)]。",
                                                           citations: [lines[6].id, lines[7].id], mediaTime: 752)), to: value.id)
        value = try await repository.append(.phase(.recording, 792), to: value.id)
        return value
    }

    /// 几门演示课程（只在内存里）：第一门在“现在”和“昨天这个时候”都上过课，所以开始页会自动认出它，昨天那堂课的横幅也会建议它。
    private static func installCourses(_ model: AppModel, repository: LessonRepository, yesterday: Lesson, math: Lesson, finish: String?) async throws -> Lesson {
        let now = Date()
        let parts = Calendar(identifier: .gregorian).dateComponents([.weekday, .hour, .minute], from: now)
        let minute = max(30, (parts.hour ?? 9) * 60 + (parts.minute ?? 0) - 2)
        let today = parts.weekday ?? 3, before = (today + 5) % 7 + 1
        let recent = now.addingTimeInterval(-86400)
        func course(_ name: String, at start: Int, days: [Int], lessons: Int) -> Course {
            var value = Course(name: name, folderName: "课堂转录", createdAt: now.addingTimeInterval(-30 * 86400))
            value.meetings = days.map { Meeting(weekday: $0, start: start, minutes: 75, count: lessons / 2, last: recent) }
            value.lessonCount = lessons; value.lastUsed = recent
            return value
        }
        let os = course("CS 3214", at: minute, days: [today, before], lessons: 12)
        let hci = course("CS 3724", at: (minute + 300) % 1320, days: [today, before], lessons: 9)
        let algorithms = course("CS 4014", at: (minute + 480) % 1320, days: [(today % 7) + 1], lessons: 8)
        let ai = course("CS 4804", at: (minute + 600) % 1320, days: [(today % 7) + 1], lessons: 6)
        var linear = course("MATH 2114", at: (minute + 720) % 1320, days: [(today + 1) % 7 + 1], lessons: 4)
        linear.archived = false
        model.courses = CourseBook(courses: [os, hci, algorithms, ai, linear])

        let files = ["课堂转录.txt", "课堂转录.vtt", "双语.md", "课堂纪要.md", "我的笔记.md", "记录信息.md"]
        try await repository.append(.filed(Filing(courseID: linear.id, courseName: linear.name, basis: "known", at: math.createdAt)), to: math.id)
        try await repository.append(.exported(ExportReceipt(at: math.createdAt.addingTimeInterval(4600), courseID: linear.id, folderName: "课堂转录",
                                                           prefix: "Week 06 - 10-2", files: files.map { "Week 06 - 10-2 \($0)" }, written: 6)), to: math.id)
        let filed = Filing(courseID: os.id, courseName: os.name, basis: "known", at: yesterday.createdAt)
        let prefix = "Week 07 - 10-4"
        // 交过的课堂都有定下的文件名开头。
        if ["delivered", "settling", "conflict"].contains(finish ?? "") {
            try await repository.append(.bound(ExportBinding(courseID: os.id, prefix: prefix, timeZoneID: os.timeZoneID)), to: yesterday.id)
        }
        let names = files.map { "\(prefix) \($0)" }
        let at = yesterday.createdAt.addingTimeInterval(4520)
        switch finish {
        case "delivered", "settling", "new":
            if finish != "new" {
                try await repository.append(.filed(filed), to: yesterday.id)
                try await repository.append(.exported(ExportReceipt(at: at, courseID: os.id, folderName: "课堂转录", prefix: prefix, files: names, written: 6)), to: yesterday.id)
            }
        case "conflict":
            try await repository.append(.filed(filed), to: yesterday.id)
            try await repository.append(.exported(ExportReceipt(at: at, courseID: os.id, folderName: "课堂转录", prefix: prefix, files: names, written: 6,
                                                               conflicts: ["\(prefix) 双语 (LectoAI 更新 1005-1047).md"])), to: yesterday.id)
        case "failed":
            try await repository.append(.filed(filed), to: yesterday.id)
            try await repository.append(.exported(ExportReceipt(at: at, courseID: os.id, folderName: "课堂转录", prefix: prefix, error: "课程文件夹需要重新选择")), to: yesterday.id)
        case "filed", "working":
            try await repository.append(.filed(filed), to: yesterday.id)
        default: break   // ask：不归课，横幅询问并建议第一门课
        }
        return try await repository.load(yesterday.id)
    }

    private static func pastLesson(_ repository: LessonRepository, title: String, daysAgo: Int, duration: Double = 64) async throws -> Lesson {
        var value = try await repository.create(title: title, source: "麦克风")
        var dated = value
        dated.createdAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        value = try await repository.append(.created(dated), to: value.id)
        let run = UUID()
        var lines: [TranscriptLine] = []
        for (index, item) in script.prefix(9).enumerated() {
            let start = Double(index) * 4 + (index >= 4 ? 10 : 0)
            let line = TranscriptLine(start: start, end: start + 3.5, original: item.0, runID: run)
            lines.append(line)
            value = try await repository.append(.line(line), to: value.id)
            value = try await repository.append(.translation(line.id, 1, item.1), to: value.id)
        }
        for (index, group) in ParagraphAssembler.groups(for: value).enumerated() where index < polished.count {
            value = try await repository.append(.paragraph(.init(id: group.id, fingerprint: group.fingerprint, text: polished[index])), to: value.id)
        }
        var important = LessonNote(line: lines[6], mediaTime: 34)
        important.mark = .important
        important.text = "期中考过：exec 返回意味着失败"
        value = try await repository.append(.note(important), to: value.id)
        value = try await repository.append(.gap(RecognitionGap(start: 52, end: 61, reason: "识别中断：测试数据")), to: value.id)
        value = try await repository.append(.chunk(.init(file: "demo.m4a", start: 0, duration: duration)), to: value.id)
        value = try await repository.append(.phase(.completed, duration), to: value.id)
        return value
    }

    /// 让演示课堂持续推进：临时文字逐词出现 → 定稿 → 逐句译文 → 段落结束后整段译文原位替换。
    private static func animate(_ model: AppModel, repository: LessonRepository, lessonID: UUID) {
        Task { @MainActor in
            let run = UUID()
            var clock = 800.0
            var sentence = 0
            let extra = Array(script.suffix(4)) + Array(script.prefix(6))
            while model.lesson?.id == lessonID, model.isRecording {
                let (english, chinese) = extra[sentence % extra.count]
                for word in english.split(separator: " ").indices {
                    model.partial = english.split(separator: " ").prefix(word + 1).joined(separator: " ")
                    clock += 0.35; model.elapsed = clock; model.level = Double.random(in: 0.3...0.8)
                    try? await Task.sleep(for: .milliseconds(350))
                }
                let line = TranscriptLine(start: clock - 3, end: clock, original: english, runID: run)
                guard let saved = try? await repository.append(.line(line), to: lessonID) else { return }
                model.partial = ""
                model.lesson = saved
                try? await Task.sleep(for: .milliseconds(700))
                if let translated = try? await repository.append(.translation(line.id, 1, chinese), to: lessonID) { model.lesson = translated }
                sentence += 1
                if sentence % 4 == 0 {
                    // 模拟老师停顿：段落结束，稍后整段译文替换草稿。
                    clock += 6; model.elapsed = clock; model.level = 0.05
                    try? await Task.sleep(for: .seconds(2))
                    if let current = model.lesson, let group = ParagraphAssembler.groups(for: current).last {
                        let text = group.lines.compactMap(\.translation).joined()
                        if let polishedValue = try? await repository.append(.paragraph(.init(id: group.id, fingerprint: group.fingerprint, text: "〔整段〕" + text)), to: lessonID) {
                            model.lesson = polishedValue
                        }
                    }
                }
            }
        }
    }
}
#endif
