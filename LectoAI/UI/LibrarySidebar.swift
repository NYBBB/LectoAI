import AppKit
import LectoAICore
import SwiftUI

/// 左侧课堂记录：按日期分组，右键重命名、在 Finder 中显示、导出、移到废纸篓。
struct LibrarySidebar: View {
    @Bindable var model: AppModel
    @State private var renaming: Lesson?
    @State private var titleDraft = ""
    @State private var trashing: Lesson?
    @State private var query = ""

    var body: some View {
        List(selection: selection) {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.lessons) { lesson in
                        LessonRow(model: model, lesson: lesson, match: searching ? snippet(in: lesson) : nil)
                            .tag(lesson.id)
                            .contextMenu { menu(for: lesson) }
                    }
                }
            }
            if searching, sections.isEmpty {
                Text("没有找到“\(query)”").font(.callout).foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: Text("搜索课堂、原文和笔记"))
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .overlay {
            if model.history.isEmpty, model.lesson == nil {
                ContentUnavailableView {
                    Label("还没有课堂记录", systemImage: "waveform")
                } description: {
                    Text("开始听课后，每堂课都会保存在这里。")
                }
            }
        }
        .alert("重命名课堂", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("课堂名称", text: $titleDraft)
            Button("保存") { if let lesson = renaming { model.rename(lesson.id, to: titleDraft) }; renaming = nil }
            Button("取消", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("把这堂课移到废纸篓？", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } })) {
            Button("移到废纸篓", role: .destructive) { if let lesson = trashing { model.moveLessonToTrash(lesson) }; trashing = nil }
        } message: {
            Text("录音、字幕和笔记会一起移到废纸篓，可从废纸篓恢复。已经导出到课程文件夹的文件不受影响。")
        }
    }

    /// 左下角：新课堂（回到开始页）与设置。
    private var bottomBar: some View {
        HStack(spacing: 6) {
            Button {
                if model.active {
                    model.toast = Toast(text: String(localized: "这堂课还在进行，先结束再开始新的一堂"))
                } else {
                    model.closeLesson()
                }
            } label: { Label("新课堂", systemImage: "plus") }
                .buttonStyle(.borderless)
                .help("回到开始页，准备新的一堂课")
                .accessibilityIdentifier("newLesson")
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("设置（⌘,）")
                .accessibilityIdentifier("openSettings")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// 录音或收尾期间不切换课堂，避免界面与正在写入的记录错位。
    private var selection: Binding<UUID?> {
        Binding(get: { model.lesson?.id }, set: { id in
            guard id != model.lesson?.id else { return }
            guard !model.active else {
                model.toast = Toast(text: String(localized: "这堂课还在进行，结束或暂停并结束后再查看其他课堂"))
                return
            }
            if let id, let lesson = model.history.first(where: { $0.id == id }) {
                let hit = searching ? matchingLine(in: lesson)?.id : nil
                model.open(lesson)
                // 从搜索结果打开：等字幕排好后跳到命中的那一句并高亮。
                if let hit { Task { try? await Task.sleep(for: .milliseconds(250)); model.highlightedLine = hit } }
            }
            else if id == nil { model.closeLesson() }
        })
    }

    @ViewBuilder private func menu(for lesson: Lesson) -> some View {
        let busy = model.active && model.lesson?.id == lesson.id
        Button("重命名…") { titleDraft = lesson.title; renaming = lesson }.disabled(busy)
        Menu("归到课程") { CourseMenuItems(model: model, lesson: lesson) }
        Button("导出…") {
            if model.lesson?.id != lesson.id { model.open(lesson) }
            model.presentExport()
        }
        .disabled(model.active)
        Button("在 Finder 中显示") { model.reveal(lesson.id) }
        Divider()
        Button("移到废纸篓…", role: .destructive) { trashing = lesson }.disabled(model.active)
    }

    private struct DaySection { let title: String; let lessons: [Lesson] }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var needle: String { query.trimmingCharacters(in: .whitespaces) }

    /// 搜索范围：标题、英文原文、中文译文、笔记、纪要。不区分大小写。
    private func matches(_ lesson: Lesson) -> Bool {
        let key = needle
        if lesson.title.localizedCaseInsensitiveContains(key) { return true }
        if model.courseName(for: lesson)?.localizedCaseInsensitiveContains(key) == true { return true }
        if matchingLine(in: lesson) != nil { return true }
        if lesson.notes.contains(where: { !$0.deleted && $0.text.localizedCaseInsensitiveContains(key) }) { return true }
        return lesson.digest?.contains { $0.title.localizedCaseInsensitiveContains(key) || $0.summary.localizedCaseInsensitiveContains(key)
            || $0.points.contains { $0.text.localizedCaseInsensitiveContains(key) } } == true
    }

    private func matchingLine(in lesson: Lesson) -> TranscriptLine? {
        let key = needle
        return lesson.lines.first { $0.original.localizedCaseInsensitiveContains(key) || ($0.translation?.localizedCaseInsensitiveContains(key) ?? false) }
    }

    /// 结果行下方显示命中的原文片段（截取关键词前后），标题命中时不显示。
    private func snippet(in lesson: Lesson) -> String? {
        let key = needle
        guard !lesson.title.localizedCaseInsensitiveContains(key),
              model.courseName(for: lesson)?.localizedCaseInsensitiveContains(key) != true else { return nil }
        let text: String
        if let line = matchingLine(in: lesson) {
            text = line.original.localizedCaseInsensitiveContains(key) ? line.original : (line.translation ?? line.original)
        } else if let note = lesson.notes.first(where: { !$0.deleted && $0.text.localizedCaseInsensitiveContains(key) }) {
            text = note.text
        } else { return nil }
        guard let range = text.range(of: key, options: .caseInsensitive) else { return text }
        let start = text.index(range.lowerBound, offsetBy: -16, limitedBy: text.startIndex) ?? text.startIndex
        return (start > text.startIndex ? "…" : "") + String(text[start...])
    }

    /// 今天 / 昨天 / 本周 / 按月份。进行中的课堂使用内存里的最新状态。
    private var sections: [DaySection] {
        var lessons = model.history
        if let current = model.lesson {
            if let index = lessons.firstIndex(where: { $0.id == current.id }) { lessons[index] = current }
            else { lessons.insert(current, at: 0) }
        }
        let calendar = Calendar.current
        let now = Date()
        var order: [String] = []
        var groups: [String: [Lesson]] = [:]
        if searching { lessons = lessons.filter(matches) }
        for lesson in lessons.sorted(by: { $0.createdAt > $1.createdAt }) {
            let title: String
            if calendar.isDateInToday(lesson.createdAt) { title = String(localized: "今天") }
            else if calendar.isDateInYesterday(lesson.createdAt) { title = String(localized: "昨天") }
            else if let days = calendar.dateComponents([.day], from: lesson.createdAt, to: now).day, days < 7 { title = String(localized: "过去 7 天") }
            else { title = lesson.createdAt.formatted(.dateTime.year().month(.wide)) }
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(lesson)
        }
        return order.map { DaySection(title: $0, lessons: groups[$0] ?? []) }
    }
}

private struct LessonRow: View {
    @Bindable var model: AppModel
    let lesson: Lesson
    var match: String?
    var body: some View {
        let current = model.lesson?.id == lesson.id
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if current && model.isRecording {
                    Image(systemName: "record.circle").foregroundStyle(.red).font(.caption)
                } else if current && model.canResume {
                    Image(systemName: "pause.circle").foregroundStyle(.orange).font(.caption)
                } else if lesson.phase == .interrupted {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                        .help("录音意外中断，已保存到中断前")
                }
                Text(lesson.title).lineLimit(1)
                // 交接顺利时不显示任何图标；只有没交到、或还没选课程时才提示。
                if let attention = model.handoffAttention(lesson) {
                    Spacer(minLength: 4)
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).font(.caption)
                        .help(attention)
                        .accessibilityLabel(Text(attention))
                } else if model.needsFilingPrompt(lesson) {
                    Spacer(minLength: 4)
                    Image(systemName: "questionmark.folder").foregroundStyle(.tertiary).font(.caption)
                        .help("还没选这堂课是哪门课")
                        .accessibilityLabel(Text("还没归到课程"))
                }
            }
            Text(detail(current: current)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let match {
                Text(match).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func detail(current: Bool) -> String {
        let time = lesson.createdAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if current && model.importing { return String(localized: "\(time) · 正在转写 \(Format.clock(model.elapsed))") }
        if current && model.isRecording { return String(localized: "\(time) · 录音中 \(Format.clock(model.elapsed))") }
        if current && model.canResume { return String(localized: "\(time) · 已暂停") }
        // 课程名放在最前：侧栏窄的时候，它比时长更值得留下。
        var parts = [model.courseName(for: lesson), time].compactMap { $0 }
        if lesson.duration > 0 { parts.append(Format.duration(lesson.duration)) }
        let notes = lesson.notes.filter { !$0.deleted }.count
        if notes > 0 { parts.append(String(localized: "\(notes) 条笔记")) }
        return parts.joined(separator: " · ")
    }
}
