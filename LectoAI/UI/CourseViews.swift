import AppKit
import LectoAICore
import SwiftUI

// MARK: 归到课程的菜单项

/// “归到课程”的菜单内容：各门课、新课程、不归档。标题菜单、侧栏右键、“不是这门课”共用。
struct CourseMenuItems: View {
    @Bindable var model: AppModel
    let lesson: Lesson

    var body: some View {
        let current = lesson.filing?.courseID
        ForEach(model.courses.active) { course in
            Button { model.file(lesson.id, to: course.id, basis: "manual") } label: {
                if course.id == current { Label(course.name, systemImage: "checkmark") } else { Text(course.name) }
            }
        }
        if !model.courses.active.isEmpty { Divider() }
        Button("新课程…") { model.beginNewCourse(for: lesson.id) }
        if !(lesson.filing != nil && current == nil) {
            Button("不归档") { model.file(lesson.id, to: nil, basis: "declined") }
        }
    }
}

// MARK: 下课横幅

/// 课堂结束后的保存与交接状态。顺利时只有一行；拿不准是哪门课时在这里问，不在上课前问。
struct HandoffBanner: View {
    @Bindable var model: AppModel
    let lesson: Lesson
    /// 刚结束的课堂在最前面写“已保存 · 时长”；重新打开的课堂只说交接的事。
    let justFinished: Bool
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Display: Equatable {
        case working(course: String)
        case delivered(course: String, detail: String)
        case conflicted(course: String, copies: Int)
        case filedOnly(course: String, short: Bool)
        case ask(suggested: UUID?)
        case noCourses
        case failed(course: String, reason: String, needsFolder: Bool)
        case declined
        /// 归属的课程已经删除或收起：不报警，只说明之后不会再更新。
        case orphan(course: String)
        /// 试录、误触这类很短的课堂：不问是哪门课。
        case short
    }

    private var display: Display {
        let name = model.courseName(for: lesson) ?? ""
        let previous = lesson.lastReceipt
        if lesson.filing?.courseID != nil, !model.courseInUse(for: lesson) { return .orphan(course: name) }
        // 只在第一次交接（或上次失败后重试）时显示进度；之后的静默更新不让横幅闪动。
        if model.handingOff.contains(lesson.id), previous == nil || previous?.error != nil { return .working(course: name) }
        switch lesson.handoffStatus {
        case .delivered(_, _, let files):
            let settling = justFinished && (model.translating || model.articleBusy || model.digestBusy)
            let detail = settling ? String(localized: "正在整理最后几段，完成后会自动更新。")
                : String(localized: "\(previous?.prefix ?? "") · \(files) 个文件")
            return .delivered(course: name, detail: detail)
        case .conflicted(_, _, let copies): return .conflicted(course: name, copies: copies.count)
        case .failed(_, let reason):
            return .failed(course: name, reason: reason, needsFolder: reason.contains("重新选择") || reason.contains("找不到"))
        case .waiting: return .filedOnly(course: name, short: model.tooShortToHandOff(lesson))
        case .declined: return .declined
        case .unfiled:
            if model.courses.active.isEmpty { return .noCourses }
            return model.tooShortToHandOff(lesson) ? .short : .ask(suggested: model.suggestion(for: lesson)?.id)
        }
    }

    private var saved: String? {
        guard justFinished else { return nil }
        return String(localized: "已保存 · \(Format.duration(lesson.duration))")
    }

    /// 横幅正文：前面的“已保存 · 时长”用次要颜色，后面的交接状态才是这一行的重点。
    private func headline(_ text: String) -> Text {
        guard let saved else { return Text(text) }
        guard !text.isEmpty else { return Text(saved) }
        return Text("\(Text(saved + " · ").foregroundStyle(.secondary))\(Text(text))")
    }

    var body: some View {
        let display = display
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon(display)
            content(display)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("关闭")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(tint(display).opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint(display).opacity(0.18)))
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: display)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("handoffBanner")
    }

    private func tint(_ display: Display) -> Color {
        switch display {
        case .delivered, .filedOnly, .noCourses, .declined, .orphan, .short: .green
        case .working, .ask: .blue
        case .conflicted, .failed: .orange
        }
    }

    @ViewBuilder private func icon(_ display: Display) -> some View {
        switch display {
        case .working:
            ProgressView().controlSize(.small).frame(width: 18)
        case .ask:
            Image(systemName: "questionmark.folder.fill").foregroundStyle(.blue).frame(width: 18)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 18)
        case .delivered, .conflicted:
            // 交接完成时对勾弹一下，是唯一的“成功”动效；减弱动态效果时不弹。
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 18)
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : lesson.receipts?.count ?? 0)
        case .filedOnly, .noCourses, .declined, .orphan, .short:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 18)
        }
    }

    @ViewBuilder private func content(_ display: Display) -> some View {
        switch display {
        case .working(let course):
            row(headline(String(localized: "正在交到“\(course)”…")), detail: nil) { EmptyView() }
        case .delivered(let course, let detail):
            row(headline(String(localized: "已交到“\(course)”")), detail: detail) {
                Button("在 Finder 中显示") { reveal() }
                Menu("不是这门课") { CourseMenuItems(model: model, lesson: lesson) }.fixedSize()
            }
        case .conflicted(let course, let copies):
            row(headline(String(localized: "已交到“\(course)”")), detail: String(localized: "有 \(copies) 个文件被改过，新内容另存了一份，原来的没有动。"), detailTint: .orange) {
                Button("查看") { reveal(); model.acknowledgeConflicts(lesson) }
            }
        case .filedOnly(let course, let short):
            row(headline(String(localized: "归在“\(course)”")),
                detail: short ? String(localized: "这堂课很短，没有自动交接。") : String(localized: "课堂记录保存在本机。")) {
                Button("交到课程文件夹") { model.requestHandoff(lesson.id, manual: true, delay: .zero) }
                Menu("不是这门课") { CourseMenuItems(model: model, lesson: lesson) }.fixedSize()
            }
        case .ask(let suggested):
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    headline(String(localized: "这堂课是哪门课？")).font(.callout)
                    if let suggested, let course = model.courses.course(suggested) {
                        Text("看时间像是“\(course.name)”。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                chips(suggested: suggested)
            }
        case .noCourses:
            row(headline(""), detail: String(localized: "课堂记录保存在本机。")) {
                Button("放进课程文件夹…") { model.beginNewCourse(for: lesson.id) }
                Button("导出…") { model.presentExport() }
            }
        case .failed(let course, let reason, let needsFolder):
            row(Text("\(justFinished ? "已保存在本机 · " : "")没能交到“\(course)”：\(reason)"), detail: nil) {
                if needsFolder, let id = lesson.filing?.courseID {
                    Button("重新选择文件夹") { model.changeFolder(of: id, retrying: lesson.id) }
                }
                Button("重试") { model.requestHandoff(lesson.id, initial: true, delay: .zero) }
            }
        case .declined:
            row(headline(""), detail: String(localized: "这堂课没有归到课程。")) {
                Button("导出…") { model.presentExport() }
            }
        case .orphan(let course):
            row(headline(String(localized: "归在“\(course)”")), detail: String(localized: "这门课已经删除或收起，之后的更新不会再交出。")) {
                Menu("归到课程") { CourseMenuItems(model: model, lesson: lesson) }.fixedSize()
            }
        case .short:
            row(headline(""), detail: String(localized: "这堂课很短，没有归到课程。")) {
                Menu("归到课程") { CourseMenuItems(model: model, lesson: lesson) }.fixedSize()
            }
        }
    }

    /// 一行放得下就正文在左、按钮在右；放不下时按钮换到正文下面，不挤掉文字。
    private func row<Actions: View>(_ text: Text, detail: String?, detailTint: Color = .secondary, @ViewBuilder actions: () -> Actions) -> some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            text.font(.callout).textSelection(.enabled)
            if let detail { Text(detail).font(.caption).foregroundStyle(detailTint) }
        }
        let buttons = HStack(spacing: 8) { actions() }.controlSize(.small).fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) { label.fixedSize(horizontal: true, vertical: false); Spacer(minLength: 8); buttons }
            VStack(alignment: .leading, spacing: 8) { label; buttons }
        }
    }

    /// 课程按钮：有建议的排第一并高亮，其余按最近使用；超过 5 门时其余收进“更多”。按钮会自动换行。
    private func chips(suggested: UUID?) -> some View {
        let all = model.courses.active
        let ordered = all.filter { $0.id == suggested } + all.filter { $0.id != suggested }
        let shown = Array(ordered.prefix(5)), rest = Array(ordered.dropFirst(5))
        return FlowLayout(spacing: 6) {
            ForEach(shown) { course in
                let action = { model.file(lesson.id, to: course.id, basis: course.id == suggested ? "confirmed" : "asked") }
                if course.id == suggested {
                    Button(course.name, action: action).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("courseChip-suggested")
                } else {
                    Button(course.name, action: action).buttonStyle(.bordered)
                }
            }
            if !rest.isEmpty {
                Menu("更多") {
                    ForEach(rest) { course in Button(course.name) { model.file(lesson.id, to: course.id, basis: "asked") } }
                }
                .fixedSize()
            }
            Button { model.beginNewCourse(for: lesson.id) } label: { Label("新课程…", systemImage: "plus") }
                .buttonStyle(.bordered)
            Button("不归档") { model.file(lesson.id, to: nil, basis: "declined") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
    }

    private func reveal() {
        if let receipt = lesson.lastReceipt { model.revealHandoff(receipt) }
    }
}

/// 按宽度自动换行的横向排列，用于数量不定的课程按钮。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        // 同一行里按钮高度不同（带图标、无边框）时按中线对齐，先量出每行的高度。
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; rows.append([]) }
            rows[rows.count - 1].append((index, size))
            x += size.width + spacing
        }
        for row in rows {
            rowHeight = row.map(\.size.height).max() ?? 0
            x = bounds.minX
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (rowHeight - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}

// MARK: 就地新建课程

/// 选完文件夹后的确认卡：名称与上课时间都已填好，回车即完成。
struct NewCourseSheet: View {
    @Bindable var model: AppModel
    let draft: CourseDraft
    @State private var name = ""
    @FocusState private var focused: Bool

    private var duplicate: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return model.courses.courses.contains { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 26)).foregroundStyle(.tint).frame(width: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("新课程").font(.title3.weight(.semibold))
                    Text(draft.lessonID == nil ? "下课后，这门课的课堂文件会放进这个文件夹。"
                         : "这堂课会放进这个文件夹；以后同一门课自动归到这里。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("名称").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("课程名称", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .focused($focused)
                            .onSubmit(confirm)
                            .accessibilityIdentifier("newCourseName")
                        if duplicate { Text("已经有一门同名的课程。").font(.caption).foregroundStyle(.orange) }
                    }
                }
                GridRow {
                    Text("文件夹").foregroundStyle(.secondary)
                    Label(draft.trail, systemImage: "folder").lineLimit(1).truncationMode(.head)
                        .help(draft.trail)
                }
                if let meeting = draft.meeting {
                    GridRow {
                        Text("上课时间").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting)
                            Text("按刚上完的这堂课记下，以后这个时间上课会自动认出来。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { model.courseDraft = nil }.keyboardShortcut(.cancelAction)
                Button("完成", action: confirm)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("newCourseConfirm")
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear { name = draft.name; focused = true }
    }

    private func confirm() { model.confirmCourse(draft, name: name) }
}

// MARK: 设置：课程

/// 设置的“课程”分页：课程列表、交接开关、文件命名。正常使用不需要打开它——课程在下课时就地建立。
struct CourseSettings: View {
    @Bindable var model: AppModel
    @AppStorage("exportTemplate") private var template = "{date} {title}"
    @AppStorage("semesterStart") private var semesterStart = 0.0
    @AppStorage("autoExport") private var autoHandoff = true
    @AppStorage("autoExportAudio") private var autoExportAudio = false
    @State private var editing: Course?
    @State private var showArchived = false

    var body: some View {
        Form {
            Section {
                let active = model.courses.active.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                if active.isEmpty {
                    Text("还没有课程。下课时在横幅上点“放进课程文件夹…”，选一次文件夹就建好了。")
                        .foregroundStyle(.secondary).font(.callout)
                }
                ForEach(active) { course in row(course) }
                let archived = model.courses.courses.filter(\.archived)
                if !archived.isEmpty {
                    DisclosureGroup("已收起的课程（\(archived.count)）", isExpanded: $showArchived) {
                        ForEach(archived) { course in row(course) }
                    }
                }
                Button("添加课程…") { model.beginNewCourse(for: nil, inSettings: true) }
            } header: {
                Text("课程")
            } footer: {
                Text("上课时间是 LectoAI 根据归到这门课的课堂自动记下的，不用填。之后到了差不多的时间，会自动认出是哪门课。")
            }
            Section {
                Toggle("下课后自动交到课程文件夹", isOn: $autoHandoff)
                Toggle("同时导出录音（m4a）", isOn: $autoExportAudio).disabled(!autoHandoff)
            } header: {
                Text("交接")
            } footer: {
                Text("本机始终保留完整记录。交出的文件如果被你改过，LectoAI 不会覆盖，而是另存一份；被你移走的文件，自动更新不会再放回来。")
            }
            Section {
                TextField("文件名开头", text: $template)
                LabeledContent("示例") { Text(preview).foregroundStyle(.secondary).textSelection(.enabled) }
                Toggle("按学期周次命名", isOn: Binding(get: { semesterStart > 0 }, set: { semesterStart = $0 ? Date().timeIntervalSince1970 : 0 }))
                if semesterStart > 0 {
                    DatePicker("学期第一周", selection: Binding(get: { Date(timeIntervalSince1970: semesterStart) }, set: { semesterStart = $0.timeIntervalSince1970 }), displayedComponents: .date)
                    Button("使用“Week 周次 - 月-日”格式") { template = "Week {week} - {M}-{D}" }
                }
            } header: {
                Text("文件命名")
            } footer: {
                Text("可用：{date} 日期、{title} 课堂名、{week} 周次、{M}/{D} 月日、{MM}/{DD} 两位月日、{time} 时分。已经交接过的课堂保持原来的名字。")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { course in CourseEditorSheet(model: model, courseID: course.id) }
        .sheet(item: settingsDraft) { draft in NewCourseSheet(model: model, draft: draft) }
    }

    /// 从设置里发起的新建课程，确认卡就出现在设置窗口上。
    private var settingsDraft: Binding<CourseDraft?> {
        Binding(get: { model.courseDraft.flatMap { $0.lessonID == nil && model.courseDraftInSettings ? $0 : nil } },
                set: { if $0 == nil { model.courseDraft = nil } })
    }

    private func row(_ course: Course) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(course.name)
                Text(detail(course)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("编辑…") { editing = course }.controlSize(.small)
        }
        .accessibilityElement(children: .combine)
    }

    private func detail(_ course: Course) -> String {
        var parts = [course.folderName]
        if !course.meetingSummary.isEmpty { parts.append(course.meetingSummary) }
        if course.lessonCount > 0 { parts.append(String(localized: "\(course.lessonCount) 堂课")) }
        return parts.joined(separator: " · ")
    }

    private var preview: String {
        var lesson = Lesson(title: model.lesson?.title ?? String(localized: "课堂名"), source: "")
        lesson.createdAt = model.lesson?.createdAt ?? Date()
        let naming = ExportNaming(template: template, semesterStart: semesterStart > 0 ? Date(timeIntervalSince1970: semesterStart) : nil)
        do { return try naming.prefix(for: lesson) + " 课堂转录.txt" } catch { return error.localizedDescription }
    }
}

/// 编辑一门课：改名、换文件夹、看自动记下的上课时间、收起或删除。
struct CourseEditorSheet: View {
    @Bindable var model: AppModel
    let courseID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmingDelete = false

    private var course: Course? { model.courses.course(courseID) }

    /// 常用时区，加上这门课现在的和系统当前的。
    private var zones: [String] {
        var values = ["America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles", "Europe/London", "Asia/Shanghai", "Asia/Tokyo"]
        for extra in [course?.timeZoneID, TimeZone.current.identifier].compactMap({ $0 }) where !values.contains(extra) { values.append(extra) }
        return values
    }

    var body: some View {
        if let course {
            VStack(spacing: 0) {
                Form {
                    Section {
                        TextField("名称", text: $name).onSubmit { model.renameCourse(courseID, to: name) }
                        LabeledContent("文件夹") {
                            HStack(spacing: 8) {
                                Text(course.folderName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Button("更换…") { model.changeFolder(of: courseID) }
                            }
                        }
                    }
                    Section {
                        if course.meetings.isEmpty {
                            Text("还没有记录。归到这门课的课堂会自动记下上课时间。").foregroundStyle(.secondary).font(.callout)
                        }
                        ForEach(Array(course.meetings.sorted { ($0.weekday + 5) % 7 < ($1.weekday + 5) % 7 }.enumerated()), id: \.offset) { _, meeting in
                            LabeledContent(Self.dayName(meeting.weekday) + " " + Course.clockText(meeting.start) + String(localized: " 左右")) {
                                Text("上过 \(meeting.count) 次").foregroundStyle(.secondary)
                            }
                        }
                        Picker("时区", selection: Binding(get: { course.timeZoneID }, set: { model.setTimeZone(of: courseID, to: $0) })) {
                            ForEach(zones, id: \.self) { zone in Text(Self.zoneName(zone)).tag(zone) }
                        }
                    } header: {
                        Text("上课时间")
                    } footer: {
                        Text("根据归到这门课的课堂自动记录。把记错课的课堂改到别的课，这里会跟着更新。时区决定认课和文件日期按哪里的时间算。")
                    }
                }
                .formStyle(.grouped)
                Divider()
                HStack {
                    Button(course.archived ? "恢复这门课" : "收起这门课") { model.setArchived(courseID, !course.archived) }
                        .help("学期结束后收起：不再自动认这门课，历史课堂和文件都保留")
                    Button("删除…", role: .destructive) { confirmingDelete = true }
                    Spacer()
                    Button("完成") { model.renameCourse(courseID, to: name); dismiss() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
                .padding(16)
            }
            .frame(width: 460, height: 440)
            .onAppear { name = course.name }
            .confirmationDialog("删除“\(course.name)”？", isPresented: $confirmingDelete) {
                Button("删除课程", role: .destructive) { model.deleteCourse(courseID); dismiss() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只删除这门课的设置，课程文件夹里的文件不受影响。")
            }
        }
    }

    static func dayName(_ weekday: Int) -> String {
        ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][max(0, min(6, weekday - 1))]
    }

    /// “美东时间（America/New_York）”这样的显示名。
    static func zoneName(_ identifier: String) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return identifier }
        let name = zone.localizedName(for: .generic, locale: .current) ?? identifier
        return identifier == TimeZone.current.identifier ? String(localized: "\(name)（当前）") : name
    }
}

// MARK: 开始页：课程

/// 开始页“课程”一行右侧的选择：默认按以往上课时间自动认，拿不准就下课再选。
struct CoursePicker: View {
    @Bindable var model: AppModel

    var body: some View {
        // 每半分钟重新认一次：坐下来等上课的几分钟里，结果会随时间变化。
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let upcoming = model.upcomingCourse
            Menu {
                ForEach(model.courses.active) { course in
                    Button { model.courseChoice = .course(course.id) } label: {
                        if model.courseChoice == .course(course.id) { Label(course.name, systemImage: "checkmark") } else { Text(course.name) }
                    }
                }
                Divider()
                Button { model.courseChoice = .later } label: {
                    if model.courseChoice == .later { Label("下课再选", systemImage: "checkmark") } else { Text("下课再选") }
                }
                if model.courseChoice != .automatic {
                    Button("按以往上课时间自动认") { model.courseChoice = .automatic }
                }
                Divider()
                Button("新课程…") { model.beginNewCourse(for: nil) }
                Button("管理课程…") { model.settingsRequest = .export }
            } label: {
                label(upcoming)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("coursePicker")
        }
    }

    private func label(_ upcoming: (course: Course, basis: String)?) -> some View {
        Group {
            switch upcoming?.basis {
            case "manual": Text(upcoming?.course.name ?? "")
            case "known": Text("\(upcoming?.course.name ?? "")\(Text(" · 按以往时间").foregroundStyle(.secondary))")
            case "guess": Text("可能是 \(upcoming?.course.name ?? "")").foregroundStyle(.secondary)
            default: Text("下课再选").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .contentTransition(.opacity)
    }
}
