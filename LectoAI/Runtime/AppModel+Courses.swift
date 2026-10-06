import AppKit
import AVFoundation
import LectoAICore
import SwiftUI

/// 开始页上为下一堂课选的课程。
enum CourseChoice: Equatable {
    /// 没选：按以往上课时间认课。
    case automatic
    case course(UUID)
    /// 明确“下课再选”。
    case later
}

/// 就地新建课程的确认卡：文件夹已经选好，名称和上课时间都先填上，用户只需确认。
struct CourseDraft: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var folderName: String
    /// 文件夹的最后三级路径，如“CS3214 › raw › 课堂转录”，让人确认选对了地方。
    var trail: String
    var bookmark: Data
    /// 建好后把这堂课归进去并交接；nil 表示只是提前建课。
    var lessonID: UUID?
    /// 这堂课的上课时间，如“周二 09:30 左右”；导入的录音和太短的课堂没有。
    var meeting: String?
}

/// 只放行一次的门：退出时“交接做完”和“等够了”谁先到算谁的。
@MainActor
private final class DrainGate {
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func open() {
        continuation?.resume()
        continuation = nil
    }
}

/// 课程、归课与交接（C1）。设计见 docs/2026-10-05-macos-course-handoff-design.md §1。
extension AppModel {
    // MARK: 读写

    static func loadCourses() -> CourseBook {
        guard let data = UserDefaults.standard.data(forKey: "courses") else { return CourseBook() }
        if let value = try? JSONDecoder().decode(CourseBook.self, from: data) { return value }
        // 读不出来时先另存一份原样数据，免得之后新建课程保存时把它盖掉。
        if UserDefaults.standard.data(forKey: "coursesUnreadable") == nil { UserDefaults.standard.set(data, forKey: "coursesUnreadable") }
        return CourseBook()
    }

    func saveCourses() {
        guard !isolatedWorkspace, let data = try? JSONEncoder().encode(courses) else { return }
        UserDefaults.standard.set(data, forKey: "courses")
    }

    /// 下课后是否自动交到课程文件夹。从没设置过时默认打开。
    var autoHandoffEnabled: Bool {
        UserDefaults.standard.object(forKey: "autoExport") == nil || UserDefaults.standard.bool(forKey: "autoExport")
    }

    // MARK: 启动与迁移

    func bootstrapCourses() async {
        guard !isolatedWorkspace else { return }
        migrateLegacyFolder()
        // 认领是幂等的，每次启动都做：上次中途退出、或当时文件夹暂时解析不了的，这次补上。
        for course in courses.courses { await adoptLegacyLessons(into: course.id) }
        relearnCourses()
        resumePendingHandoffs()
    }

    /// 0.4.x 的单一课程文件夹变成第一门课，只做一次，不弹任何界面。从没打开过自动导出的，保持关闭。
    private func migrateLegacyFolder() {
        let defaults = UserDefaults.standard
        guard courses.courses.isEmpty, !defaults.bool(forKey: "coursesMigrated"), let data = defaults.data(forKey: "exportBookmark") else { return }
        defaults.set(true, forKey: "coursesMigrated")
        var stale = false
        let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        let folderName = url?.lastPathComponent ?? defaults.string(forKey: "exportTargetName") ?? String(localized: "课程文件夹")
        if defaults.object(forKey: "autoExport") == nil { defaults.set(false, forKey: "autoExport") }
        courses.courses.append(Course(name: url.map(CourseBook.suggestedName(for:)) ?? folderName, folderBookmark: data, folderName: folderName))
    }

    /// 把升级前交到过这门课文件夹的旧课堂认领过来，这样已经用了几周的人马上就有上课时间记录。
    /// 只比对本机留下的账本，不读课程文件夹里的内容；对不上的旧课堂保持未归课。
    func adoptLegacyLessons(into courseID: UUID) async {
        guard !isolatedWorkspace, let repository, let course = courses.course(courseID), let path = folderPath(of: course) else { return }
        let candidates = history.filter { $0.filing == nil && ($0.phase == .completed || $0.phase == .interrupted) }
        var adopted = false
        for lesson in candidates {
            do {
                guard try await repository.adoptLegacyExport(lesson.id, folderPath: path, courseID: courseID, timeZoneID: course.timeZoneID) != nil else { continue }
                try await repository.append(.filed(Filing(courseID: courseID, courseName: course.name, basis: "migrated", at: lesson.createdAt)), to: lesson.id)
                adopted = true
            } catch { continue }
        }
        guard adopted else { return }
        await refreshHistory()
        if let id = lesson?.id, let fresh = history.first(where: { $0.id == id }) { adopt(fresh) }
    }

    /// 课程文件夹的路径（不开始访问，只用于比对）。
    func folderPath(of course: Course) -> String? {
        guard let data = course.folderBookmark else { return nil }
        var stale = false
        return (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale))?
            .standardizedFileURL.path
    }

    /// 上课时间记录由归了课的课堂重新统计：改归、删除课堂之后不会留下旧数据。演示数据自带上课时间，不重算。
    func relearnCourses() {
        guard !isolatedWorkspace, !courses.courses.isEmpty else { return }
        var rebuilt = courses
        rebuilt.relearn(from: history)
        if rebuilt != courses { courses = rebuilt }
    }

    // MARK: 认课

    /// 开始页手动选的课程多久之后不再算数：选了却没上课、App 也没退的话，不能把第二天的课归到它。
    private static let choiceLifetime: TimeInterval = 3 * 3600

    /// 下一堂课会归到哪门课：手动选的优先，其次按以往上课时间。`guess` 只是建议，下课时要用户确认。
    var upcomingCourse: (course: Course, basis: String)? {
        let fresh = Date().timeIntervalSince(courseChoiceAt) < Self.choiceLifetime
        switch fresh ? courseChoice : .automatic {
        case .course(let id): return courses.course(id).map { ($0, "manual") }
        case .later: return nil
        case .automatic: return courses.suggest(at: Date()).map { ($0.course, $0.confidence == .known ? "known" : "guess") }
        }
    }

    /// 新课堂创建后：导入的录音记下录制时间；现场课在手动选了、或以往时间靠得住时直接归课，其余留到下课再问。
    func prepareFiling(for lesson: Lesson, importedFrom file: URL?) async -> Lesson {
        guard let repository else { return lesson }
        if let file {
            guard let recorded = await Self.recordingDate(of: file), recorded < Date() else { return lesson }
            return (try? await repository.append(.recordedAt(recorded), to: lesson.id)) ?? lesson
        }
        defer { courseChoice = .automatic }
        guard let upcoming = upcomingCourse, upcoming.basis != "guess" else { return lesson }
        let filing = Filing(courseID: upcoming.course.id, courseName: upcoming.course.name, basis: upcoming.basis)
        return (try? await repository.append(.filed(filing), to: lesson.id)) ?? lesson
    }

    /// 录音文件自带的创建时间；没有就用文件的创建时间。
    private nonisolated static func recordingDate(of file: URL) async -> Date? {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        if let item = try? await AVURLAsset(url: file).load(.creationDate), let date = try? await item.load(.dateValue) { return date }
        return (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// 这堂课显示的课程名：课程改过名时用新名字，课程被删后用归课时的名字。
    func courseName(for lesson: Lesson) -> String? {
        guard let filing = lesson.filing, let id = filing.courseID else { return nil }
        return courses.course(id)?.name ?? filing.courseName
    }

    /// 这堂课归属的课程是否还在用（没被删除、没被收起）。
    func courseInUse(for lesson: Lesson) -> Bool {
        guard let course = courses.course(lesson.filing?.courseID) else { return false }
        return !course.archived
    }

    /// 没归课的课堂要不要提示归档：已有课程、是第一门课建立之后录的、7 天以内、不是试录。升级后不催旧课堂。
    func needsFilingPrompt(_ lesson: Lesson) -> Bool {
        guard lesson.filing == nil, lesson.phase == .completed || lesson.phase == .interrupted, !courses.active.isEmpty,
              !tooShortToHandOff(lesson), let first = courses.courses.map(\.createdAt).min() else { return false }
        return lesson.createdAt > first && Date().timeIntervalSince(lesson.createdAt) < 7 * 86400
    }

    /// 交接出了需要用户知道的事（没交到，或有没看过的冲突副本），返回一句说明。课程删了或收起后不再报警。
    func handoffAttention(_ lesson: Lesson) -> String? {
        guard courseInUse(for: lesson) else { return nil }
        switch lesson.handoffStatus {
        case .failed(_, let reason): return String(localized: "没能交到课程文件夹：\(reason)")
        case .conflicted(_, _, let copies): return String(localized: "有 \(copies.count) 个文件被改过，新内容另存了一份")
        default: return nil
        }
    }

    /// 下课横幅里排第一并高亮的建议：按这堂课开始的时刻认课。导入的录音不猜。
    func suggestion(for lesson: Lesson) -> Course? {
        guard lesson.source != Lesson.importedSource else { return nil }
        return courses.suggest(at: lesson.createdAt)?.course
    }

    /// 靠得住的建议才用来预选（导出面板）：只是猜的不预选，免得一按回车就归错课。
    func confidentSuggestion(for lesson: Lesson) -> Course? {
        guard lesson.source != Lesson.importedSource, let found = courses.suggest(at: lesson.createdAt), found.confidence == .known else { return nil }
        return found.course
    }

    /// 太短的课堂不自动交接、也不催归档（试录、误触）。
    func tooShortToHandOff(_ lesson: Lesson) -> Bool { lesson.duration < 120 || lesson.lines.isEmpty }

    /// 这堂课的上课时间，如“周二 09:30 左右”。导入的录音和不到 10 分钟的课堂没有。
    func meetingText(for lesson: Lesson) -> String? {
        guard lesson.source != Lesson.importedSource, lesson.duration >= 600 else { return nil }
        let parts = Calendar(identifier: .gregorian).dateComponents([.weekday, .hour, .minute], from: lesson.createdAt)
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let day = names[max(0, min(6, (parts.weekday ?? 1) - 1))]
        return String(localized: "\(day) \(Course.clockText((parts.hour ?? 0) * 60 + (parts.minute ?? 0))) 左右")
    }

    // MARK: 下课

    /// 课堂结束或中断后：已经归课的立刻交一次（合盖就走也来得及）；没归课的等用户在横幅里选。
    func settleFiling(_ id: UUID) {
        guard let lesson, lesson.id == id, lesson.phase == .completed || lesson.phase == .interrupted else { return }
        guard lesson.filing?.courseID != nil, autoHandoffEnabled, !tooShortToHandOff(lesson) else { return }
        requestHandoff(id, initial: true, delay: .zero)
    }

    /// 启动时补交：近三天已归课、课程在用、已结束的课堂逐个核对一遍。
    /// 退出时没来得及交的、上次失败的、收尾结果在退出前没同步出去的，靠它补上；内容没变的不会写任何文件。
    func resumePendingHandoffs() {
        guard !isolatedWorkspace, autoHandoffEnabled else { return }
        let cutoff = Date().addingTimeInterval(-3 * 86400)
        for lesson in history where lesson.createdAt > cutoff && (lesson.phase == .completed || lesson.phase == .interrupted) {
            guard lesson.filing?.courseID != nil, courseInUse(for: lesson), !tooShortToHandOff(lesson) else { continue }
            requestHandoff(lesson.id, initial: true, delay: .zero)
        }
    }

    // MARK: 归课

    /// 把课堂归到一门课（`courseID` 为 nil 表示明确不归档）。已经结束的课堂随后交接；`handOff` 为 nil 时按“自动交接”设置。
    func file(_ lessonID: UUID, to courseID: UUID?, basis: String, handOff: Bool? = nil) {
        guard let repository else { return }
        let course = courses.course(courseID)
        guard courseID == nil || course != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                // 上一次交接还没做完（例如正在合成录音）时先等它，才能看到它交出了哪些文件。
                await self.handoffChain?.value
                let previous = try await repository.load(lessonID)
                if let filing = previous.filing, filing.courseID == courseID {
                    // 归属没变：只有明确要求时再交一次。
                    if handOff == true, courseID != nil { self.requestHandoff(lessonID, manual: true, initial: true, delay: .zero) }
                    return
                }
                let filing = Filing(courseID: courseID, courseName: course?.name ?? "", basis: courseID == nil ? "declined" : basis)
                let value = try await repository.append(.filed(filing), to: lessonID)
                self.adopt(value)
                await self.refreshHistory()
                let moved = self.announceLeftBehind(previous, destination: course?.name)
                guard courseID != nil, value.phase == .completed || value.phase == .interrupted else { return }
                guard handOff ?? (self.autoHandoffEnabled && !self.tooShortToHandOff(value)) else { return }
                // 已经提示过“旧文件还在”时不再用“已交到”的提示把它顶掉。
                self.requestHandoff(lessonID, manual: handOff == true && !moved, initial: true, delay: .zero)
            } catch { self.message = error.localizedDescription }
        }
    }

    /// 课堂从一门课改到别处之后：之前交出的文件留在原来的课程文件夹里，告诉用户并帮他选中。App 不删除交出去的文件。
    @discardableResult
    private func announceLeftBehind(_ previous: Lesson, destination: String?) -> Bool {
        guard let old = previous.filing?.courseID, let receipt = previous.receipts?.last(where: { $0.courseID == old && $0.error == nil }),
              !receipt.files.isEmpty else { return false }
        let from = courses.course(old)?.name ?? previous.filing?.courseName ?? ""
        let text = destination.map { String(localized: "已改到“\($0)”。之前放进“\(from)”的 \(receipt.files.count) 个文件还在那里。") }
            ?? String(localized: "这堂课不再归到“\(from)”。之前放进去的 \(receipt.files.count) 个文件还在那里。")
        toast = Toast(text: text, action: String(localized: "在 Finder 中选中")) { [weak self] in self?.revealHandoff(receipt) }
        return true
    }

    // MARK: 就地新建课程

    /// 选文件夹，然后出确认卡。选到的文件夹已经属于某门课时不新建，直接归到那门课。
    func beginNewCourse(for lessonID: UUID?, inSettings: Bool = false) {
        if !inSettings { presentMain?() }
        courseDraftInSettings = inSettings
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = String(localized: "选择")
        panel.message = String(localized: "选择这门课放课堂文件的文件夹")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        if let existing = courses.courses.first(where: { folderPath(of: $0) == path }) {
            if existing.archived { setArchived(existing.id, false) }
            if let lessonID { file(lessonID, to: existing.id, basis: "asked", handOff: true) }
            else if !inSettings { courseChoice = .course(existing.id) }
            toast = Toast(text: String(localized: "这个文件夹已经是“\(existing.name)”的"))
            return
        }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            let trail = url.standardizedFileURL.pathComponents.filter { $0 != "/" }.suffix(3).joined(separator: " › ")
            let source = lessonID.flatMap { id in lesson?.id == id ? lesson : history.first { $0.id == id } }
            courseDraft = CourseDraft(name: CourseBook.suggestedName(for: url), folderName: url.lastPathComponent, trail: trail,
                                      bookmark: bookmark, lessonID: lessonID, meeting: source.flatMap { meetingText(for: $0) })
        } catch { message = "无法记住这个文件夹：\(error.localizedDescription)" }
    }

    /// 确认卡点“完成”：建好课程；有课堂在等就把它归进去并交接；从开始页提前建的，把这门课选给下一堂。
    func confirmCourse(_ draft: CourseDraft, name: String) {
        // 回车可能同时触发输入框的提交和默认按钮：同一张卡只处理一次，否则会建出两门同文件夹的课。
        guard courseDraft?.id == draft.id else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let course = Course(name: trimmed.isEmpty ? draft.folderName : String(trimmed.prefix(60)), folderBookmark: draft.bookmark, folderName: draft.folderName)
        courses.courses.append(course)
        courseDraft = nil
        if let lessonID = draft.lessonID { file(lessonID, to: course.id, basis: "created", handOff: true) }
        else if !courseDraftInSettings { courseChoice = .course(course.id) }
        Task { await adoptLegacyLessons(into: course.id) }
    }

    // MARK: 课程维护（设置页）

    func renameCourse(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = courses.courses.firstIndex(where: { $0.id == id }) else { return }
        courses.courses[index].name = String(trimmed.prefix(60))
    }

    func setArchived(_ id: UUID, _ archived: Bool) {
        guard let index = courses.courses.firstIndex(where: { $0.id == id }) else { return }
        courses.courses[index].archived = archived
        if archived, courseChoice == .course(id) { courseChoice = .automatic }
    }

    func setTimeZone(of id: UUID, to identifier: String) {
        guard TimeZone(identifier: identifier) != nil, let index = courses.courses.firstIndex(where: { $0.id == id }) else { return }
        courses.courses[index].timeZoneID = identifier
        relearnCourses()
    }

    /// 只删除这门课的设置：课程文件夹里的文件不动，历史课堂保留课程名。
    func deleteCourse(_ id: UUID) {
        courses.courses.removeAll { $0.id == id }
        if courseChoice == .course(id) { courseChoice = .automatic }
    }

    /// 重新选择课程文件夹（授权失效，或文件夹换了地方）。随后重试这堂课的交接。
    func changeFolder(of id: UUID, retrying lessonID: UUID? = nil) {
        guard let index = courses.courses.firstIndex(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = String(localized: "选择")
        panel.message = String(localized: "选择“\(courses.courses[index].name)”放课堂文件的文件夹")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            courses.courses[index].folderBookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            courses.courses[index].folderName = url.lastPathComponent
            if let lessonID { requestHandoff(lessonID, initial: true, delay: .zero) }
        } catch { message = "无法记住这个文件夹：\(error.localizedDescription)" }
    }

    // MARK: 交接

    /// 自动触发的更新（译文、纪要、笔记有变化）：只跟进已经交过的课堂，只更新它自己归属的课程。
    func autoHandoff(_ id: UUID) {
        guard autoHandoffEnabled else { return }
        requestHandoff(id)
    }

    /// 把课堂交到它归属的课程文件夹。所有交接排成一队串行执行；同一堂课连续的自动触发合并为一次。
    /// - `manual`：用户主动要求——被移走的文件会重新生成，完成后给提示。
    /// - `initial`：允许这是第一次交接。只有下课、归课、重试、启动补交才传；译文、笔记这类后续触发不传，
    ///   所以太短的课堂、自动交接关着时结束的课堂不会被它们顺带交出去。
    /// - `rename`：导出面板里改的名字，另存一套。
    func requestHandoff(_ id: UUID, manual: Bool = false, initial: Bool = false, rename: String? = nil, only: Set<String>? = nil, audio: Bool? = nil,
                        delay: Duration = .milliseconds(1500)) {
        handoffDebounce[id]?.cancel()
        handoffDebounce[id] = nil
        let enqueue: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let previous = self.handoffChain
            self.handoffChain = Task { [weak self] in
                await previous?.value
                await self?.performHandoff(id, manual: manual, initial: initial, rename: rename, only: only, audio: audio)
            }
        }
        guard delay > .zero else { enqueue(); return }
        handoffDebounce[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.handoffDebounce[id] = nil
            enqueue()
        }
    }

    /// 退出前把排队中和进行中的交接做完（设上限），避免“已保存但没交到”。做不完的由下次启动补交。
    func drainHandoffs(timeout: Duration = .seconds(8)) async {
        // 还在等合并的自动更新不再等，直接排进队里。
        for id in Array(handoffDebounce.keys) { requestHandoff(id, delay: .zero) }
        guard let chain = handoffChain else { return }
        // 不用任务组：任务组要等所有子任务结束才返回，而“等另一个任务的结果”不响应取消，
        // 交接卡住时上限就形同虚设、App 退不出去。这里谁先到算谁的。
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = DrainGate(continuation)
            Task { await chain.value; gate.open() }
            Task { try? await Task.sleep(for: timeout); gate.open() }
        }
    }

    /// 取快照（资料库队列内）→ 写盘（队列外）→ 登记结果。失败时把原因记进这堂课。
    private func performHandoff(_ id: UUID, manual: Bool, initial: Bool, rename: String?, only: Set<String>?, audio: Bool?) async {
        guard let repository, let current = try? await repository.load(id), let courseID = current.filing?.courseID else { return }
        guard let course = courses.course(courseID), manual || !course.archived else {
            if manual { toast = Toast(text: String(localized: "这门课已经删除，文件没有交出。可以把这堂课归到别的课。")) }
            return
        }
        let finished = current.phase == .completed || current.phase == .interrupted
        let bound = current.bindings?.contains { $0.courseID == courseID } == true
        // 自动更新只跟进已经交过的课堂；第一次交接只在下课、归课、重试或用户主动要求时发生。
        guard manual || (finished && (initial || bound)) else { return }
        handingOff.insert(id)
        defer { handingOff.remove(id) }
        var prefix = current.binding?.prefix ?? ""
        do {
            let folder = try resolveFolder(of: course)
            defer { folder.stopAccessingSecurityScopedResource() }
            var snapshot = try await repository.handoffSnapshot(id, courseID: courseID, only: only ?? Set(LessonText.projectionNames).subtracting(exportExcluded))
            // 改了名字：当作第一次交接，另存一套，之前的不动。
            if let rename, rename != snapshot.binding?.prefix { snapshot.binding = nil; snapshot.ledger = [:] }
            // 已经定下开头的课堂不再重算命名模板：之后改了模板或学期起点，也不影响它的更新。
            let base = try rename ?? snapshot.binding?.prefix ?? basePrefix(for: snapshot.lesson, course: course)
            // 这门课里其他课堂定下的开头不能再用：它们的文件可能已被归档走，文件夹里看不到。
            let reserved = Set(history.filter { $0.id != id }.compactMap { other in other.bindings?.first { $0.courseID == courseID }?.prefix })
            let frozen = snapshot
            let outcome = await Task.detached(priority: .utility) {
                HandoffWriter.write(frozen, into: folder, basePrefix: base, manual: manual, reserved: reserved)
            }.value
            prefix = outcome.prefix
            // 文字写完立刻登记（开头、账本、结果）。录音合成慢，也可能失败，放在后面单独处理，不拖累文字的登记。
            var updated = try await repository.recordHandoff(snapshot, outcome: outcome, folderName: course.folderName, timeZoneID: course.timeZoneID)
            absorb(updated)
            guard outcome.failure == nil else { return }
            if audio ?? UserDefaults.standard.bool(forKey: "autoExportAudio") {
                // 上次交出的录音被移走了：和文字一样，自动更新不再放回，手动导出才重新生成。
                let previousAudio = current.receipts?.last { $0.courseID == courseID && $0.error == nil }?.audio
                let removed = previousAudio.map { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) } ?? false
                if manual || !removed {
                    do {
                        if let name = try await exportAudio(snapshot.lesson, into: folder, prefix: outcome.prefix) {
                            updated = try await repository.recordHandoffAudio(id, courseID: courseID, audio: name)
                            absorb(updated)
                        }
                    } catch { message = String(localized: "文字已经交到“\(course.name)”，录音没能导出：\(error.localizedDescription)") }
                }
            }
            if manual, justFinishedID != id, let receipt = updated.lastReceipt {
                toast = Toast(text: String(localized: "已交到“\(course.name)”"), action: String(localized: "在 Finder 中显示")) { [weak self] in
                    self?.revealHandoff(receipt)
                }
            }
        } catch {
            if let updated = try? await repository.recordHandoffFailure(id, courseID: courseID, folderName: course.folderName, prefix: prefix,
                                                                        error: error.localizedDescription) { absorb(updated) }
        }
    }

    /// 更新当前课堂与侧栏里的那一条。
    func absorb(_ value: Lesson) {
        adopt(value)
        if let index = history.firstIndex(where: { $0.id == value.id }), value.sequence >= history[index].sequence { history[index] = value }
    }

    /// 解析课程文件夹并开始安全作用域访问；调用方负责 stopAccessingSecurityScopedResource。授权过期但仍可访问时顺手刷新。
    func resolveFolder(of course: Course) throws -> URL {
        #if DEBUG
        if isolatedWorkspace {
            // 演示与界面测试：写进临时目录，不碰真实的课程文件夹。
            let demo = FileManager.default.temporaryDirectory.appendingPathComponent("LectoAI-DemoCourses/\(course.id.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: demo, withIntermediateDirectories: true)
            return demo
        }
        #endif
        guard let data = course.folderBookmark else { throw CaptureFailure(String(localized: "课程文件夹需要重新选择")) }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { throw CaptureFailure(String(localized: "课程文件夹需要重新选择")) }
        var isDirectory: ObjCBool = false
        // 书签会跟着文件夹走：被拖进废纸篓的文件夹也解析得出来，不能往那里写。
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              !url.standardizedFileURL.pathComponents.contains(".Trash") else {
            url.stopAccessingSecurityScopedResource()
            throw CaptureFailure(String(localized: "找不到课程文件夹，可能被移走或删除了"))
        }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
           let index = courses.courses.firstIndex(where: { $0.id == course.id }) {
            courses.courses[index].folderBookmark = fresh
            courses.courses[index].folderName = url.lastPathComponent
        }
        return url
    }

    /// 第一次交到课程时算出的文件名开头：导出面板里起过名字的用那个名字，否则按命名模板。
    /// 日期按课程的时区；标题还是默认的日期标题时用课程名，不等 AI 起名。
    func basePrefix(for lesson: Lesson, course: Course) throws -> String {
        if let custom = exportNames[lesson.id.uuidString] { return custom }
        let untitled = lesson.title == Self.defaultTitle(for: lesson.createdAt)
        return try exportNaming.prefix(for: lesson, timeZone: course.timeZone, title: untitled ? course.name : nil)
    }

    /// 导出面板里显示的名字：已经交到这门课的用定下的开头，否则是将要用的开头。
    func handoffPrefix(for lesson: Lesson, courseID: UUID) -> String? {
        if let bound = lesson.bindings?.first(where: { $0.courseID == courseID }) { return bound.prefix }
        return courses.course(courseID).flatMap { try? basePrefix(for: lesson, course: $0) }
    }

    /// 导出面板确认（交到课程）：把这堂课归到这门课，按面板里的名字与勾选交接。勾选跨课堂记住。
    func exportToCourse(_ courseID: UUID, name: String, files: Set<String>, shown: Set<String>, audio: Bool) {
        guard let repository, let lesson, !active, let course = courses.course(courseID) else { return }
        let cleaned: String
        do { cleaned = try ExportNaming.clean(name) } catch { message = error.localizedDescription; return }
        exportExcluded = exportExcluded.subtracting(shown).union(shown.subtracting(files))
        let id = lesson.id
        // 名字和这堂课已有的（或将要用的）开头不同，才算手动改名。
        let rename = cleaned == handoffPrefix(for: lesson, courseID: courseID) ? nil : cleaned
        Task { [weak self] in
            guard let self else { return }
            var moved = false
            if lesson.filing?.courseID != courseID {
                do {
                    await self.handoffChain?.value
                    let previous = try await repository.load(id)
                    self.adopt(try await repository.append(.filed(Filing(courseID: courseID, courseName: course.name, basis: "manual")), to: id))
                    await self.refreshHistory()
                    moved = self.announceLeftBehind(previous, destination: course.name)
                } catch { self.message = error.localizedDescription; return }
            }
            self.requestHandoff(id, manual: !moved, initial: true, rename: rename, only: files, audio: audio, delay: .zero)
        }
    }

    /// 在 Finder 里选中一次交接交出的文件（冲突副本连同它对应的原文件）；一个都找不到时打开课程文件夹。
    func revealHandoff(_ receipt: ExportReceipt) {
        guard let course = courses.course(receipt.courseID), let folder = try? resolveFolder(of: course) else {
            toast = Toast(text: String(localized: "找不到这门课的文件夹"))
            return
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        let names = receipt.files + receipt.conflicts + receipt.conflicts.map(HandoffWriter.original(ofCopy:)) + [receipt.audio].compactMap { $0 }
        var seen = Set<String>()
        let urls = names.filter { seen.insert($0).inserted }.map { folder.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [folder] : urls)
    }

    /// 用户看过冲突副本（点了“查看”或关掉了提示）：不再提醒。
    func acknowledgeConflicts(_ lesson: Lesson) {
        guard let repository, let courseID = lesson.filing?.courseID, case .conflicted = lesson.handoffStatus else { return }
        Task { [weak self] in
            if let updated = try? await repository.acknowledgeConflicts(lesson.id, courseID: courseID) { self?.absorb(updated) }
        }
    }
}
