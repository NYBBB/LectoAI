import AppKit
import LectoAICore
import SwiftUI

/// 导出面板：选交到哪门课（或一次性位置）、给这次导出起名、勾选要导出的文件。
/// 勾选跨课堂记住（自动交接也按此）；名字只属于这堂课，之后的更新沿用，不会多出第二套文件。
struct ExportSheet: View {
    @Bindable var model: AppModel
    let lesson: Lesson
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportAudio") private var audio = false
    @State private var name = ""
    @State private var items: [(file: String, title: String, detail: String)] = []
    @State private var selected: Set<String> = []
    @State private var target: Target = .other
    @State private var folder: URL?

    /// 交到一门课（这堂课随之归到它），或只用于这一次的其他位置。
    private enum Target: Hashable { case course(UUID), other }

    private var cleanName: String? { try? ExportNaming.clean(name) }
    private var hasAudio: Bool { !lesson.audio.isEmpty }
    private var exportsAudio: Bool { hasAudio && audio }
    /// 打开面板时的课堂是快照；交接记录以模型里的最新状态为准。
    private var current: Lesson { model.lesson?.id == lesson.id ? model.lesson ?? lesson : lesson }

    private var courseID: UUID? { if case .course(let id) = target { id } else { nil } }
    private var ready: Bool { courseID != nil || folder != nil }

    /// 打开面板或换目标时填进去的名字：交到课程时是定下的（或将要用的）开头；其他位置是这堂课上次导出用的名字，没有就按命名模板。
    private var defaultName: String? {
        if let courseID { return model.handoffPrefix(for: current, courseID: courseID) }
        return try? model.exportPrefix(for: lesson)
    }

    /// “恢复”链接回到的名字：交到课程时是原来定下的开头，其他位置是命名模板的结果。
    private var restoreName: String? {
        if let courseID { return model.handoffPrefix(for: current, courseID: courseID) }
        return try? model.exportNaming.prefix(for: lesson)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                destination
                Section {
                    TextField("文件名开头", text: $name, prompt: Text(lesson.title))
                        .accessibilityIdentifier("exportName")
                } header: {
                    Text("命名")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if cleanName == nil {
                            Text("请输入名字。").foregroundStyle(.red)
                        } else {
                            Text("这堂课之后再导出也沿用这个名字。改名后会另存一套文件，之前导出的不会删除。")
                        }
                        if let restoreName, cleanName != restoreName {
                            Button(courseID == nil ? "恢复按模板命名：\(restoreName)" : "恢复原来的名字：\(restoreName)") { name = restoreName }
                                .buttonStyle(.link)
                                .accessibilityIdentifier("exportRestoreName")
                        }
                    }
                }
                Section {
                    ForEach(items, id: \.file) { item in
                        Toggle(isOn: binding(item.file)) { row(item.title, file: "\(cleanName ?? "…") \(item.file)", detail: item.detail) }
                            .accessibilityIdentifier("exportFile-\(item.file)")
                    }
                    if hasAudio {
                        Toggle(isOn: $audio) { row(String(localized: "录音"), file: "\(cleanName ?? "…") 录音 \(lesson.id.uuidString.prefix(8)).m4a", detail: String(localized: "整堂课合成一个文件，较大")) }
                    }
                } header: {
                    HStack {
                        Text("文件")
                        Spacer()
                        Button(selected.count == items.count ? "全不选" : "全选") {
                            selected = selected.count == items.count ? [] : Set(items.map(\.file))
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                } footer: {
                    Text("勾选会记住，下次导出和下课后的自动交接也按这里。")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text(summary).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(ready ? (courseID == nil ? "导出" : "交到课程文件夹") : "选择位置并导出…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(cleanName == nil || (selected.isEmpty && !exportsAudio))
                    .accessibilityIdentifier("exportConfirm")
            }
            .padding(16)
        }
        .frame(width: 500, height: 660)
        .onAppear(perform: load)
        .onChange(of: target) { _, _ in name = defaultName ?? lesson.title }
    }

    /// “交到”：各门课，或其他位置。选一门课就是把这堂课归到它。
    @ViewBuilder private var destination: some View {
        Section {
            Picker("交到", selection: $target) {
                ForEach(model.courses.active) { course in Text(course.name).tag(Target.course(course.id)) }
                if !model.courses.active.isEmpty { Divider() }
                Text("其他位置").tag(Target.other)
            }
            .accessibilityIdentifier("exportTarget")
            if let courseID {
                if let receipt = current.receipts?.last(where: { $0.courseID == courseID && $0.error == nil }) {
                    LabeledContent("上次交接") {
                        HStack(spacing: 8) {
                            Text("\(receipt.at.formatted(.dateTime.month().day().hour().minute())) · \(receipt.files.count) 个文件")
                                .foregroundStyle(.secondary)
                            Button("在 Finder 中显示") { model.revealHandoff(receipt) }.controlSize(.small)
                        }
                    }
                    ForEach(receipt.conflicts, id: \.self) { copy in
                        Label("有文件被改过，新内容另存为“\(copy)”", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !receipt.skipped.isEmpty {
                        Label("已被你移走、没有再放回的文件：\(receipt.skipped.joined(separator: "、"))。在这里导出会重新生成。", systemImage: "arrow.uturn.backward")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                LabeledContent("位置") {
                    HStack(spacing: 8) {
                        Text(folder.map { "“\($0.lastPathComponent)”" } ?? String(localized: "未选择")).foregroundStyle(.secondary).lineLimit(1)
                        Button(folder == nil ? "选择…" : "更换…") { choose() }
                    }
                }
            }
        } footer: {
            Text(courseID == nil ? "只用于这一次，不改变这堂课归到哪门课。"
                 : "这堂课会归到这门课。之后笔记、译文有更新，会自动同步到它的文件夹。")
        }
    }

    private func row(_ title: String, file: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.tertiary)
            }
            Text(file).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    private var summary: String {
        let count = selected.count + (exportsAudio ? 1 : 0)
        return count == 0 ? String(localized: "没有选择文件") : String(localized: "\(count) 个文件")
    }

    private func binding(_ file: String) -> Binding<Bool> {
        Binding(get: { selected.contains(file) }, set: { if $0 { selected.insert(file) } else { selected.remove(file) } })
    }

    /// 只列出这堂课有内容的文件；默认勾选沿用上次。默认交到这堂课归属的课程；没归课时只有按上课时间靠得住才预选，
    /// 只是猜的不预选——这里按回车就会归课并交接，不能替用户猜。
    private func load() {
        let files = LessonText.files(for: lesson)
        items = LessonText.exportCatalog.filter { files[$0.file] != nil }
        selected = Set(items.map(\.file)).subtracting(model.exportExcluded)
        let active = Set(model.courses.active.map(\.id))
        if let filed = current.filing?.courseID, active.contains(filed) { target = .course(filed) }
        else if current.filing == nil, let suggested = model.confidentSuggestion(for: current)?.id { target = .course(suggested) }
        #if DEBUG
        // 界面测试：导出到指定的临时目录，不碰真实课程文件夹，也不弹选择面板。
        // “auto” 用 App 自己的临时目录：沙盒里一定可写，而测试运行器建的目录 App 未必写得进去。
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--demo-export-dir"), index + 1 < arguments.count {
            let value = arguments[index + 1]
            let url = value == "auto" ? FileManager.default.temporaryDirectory.appendingPathComponent("LectoAI-ExportDemo", isDirectory: true)
                : URL(fileURLWithPath: value, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            folder = url
            target = .other
        }
        #endif
        name = defaultName ?? lesson.title
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = String(localized: "选择")
        panel.message = String(localized: "选择这次导出的位置（只用于这次）。")
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    private func export() {
        let shown = Set(items.map(\.file))
        if let courseID {
            model.exportToCourse(courseID, name: name, files: selected, shown: shown, audio: exportsAudio)
        } else {
            if folder == nil { choose() }
            guard let folder else { return }
            model.export(name: name, files: selected, shown: shown, audio: exportsAudio, to: folder)
        }
        dismiss()
    }
}
