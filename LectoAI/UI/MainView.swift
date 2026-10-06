import AppKit
import LectoAICore
import SwiftUI
import Translation

/// 主窗口：左侧课堂记录，中间字幕（或开始页），右侧可收起的 AI 助手。
struct MainView: View {
    @Bindable var model: AppModel
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 340)
        } detail: {
            LessonDetail(model: model)
                .inspector(isPresented: $model.showAssistant) {
                    AssistantPanel(model: model)
                        .inspectorColumnWidth(min: 290, ideal: 340, max: 480)
                }
        }
        // 不要在分栏视图外层再加 .frame(minWidth:minHeight:)：它和各栏最小宽度一起换算窗口约束，
        // 窗口宽度偏离启动尺寸时会反复重算直到 AppKit 抛异常崩溃。最小尺寸只由窗口 minSize 决定。
        .overlay(alignment: .bottom) { ToastOverlay(model: model).padding(.bottom, 84) }
        .translationTask(model.translationRequest, action: prepareTranslation)
        .onChange(of: model.settingsRequest) { _, tab in
            guard let tab else { return }
            UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab")
            openSettings()
            model.settingsRequest = nil
        }
        .sheet(isPresented: $model.showStudyDraft) { StudyDraftSheet(model: model) }
        .sheet(isPresented: $model.showAICalls) { AICallsSheet(model: model) }
        .sheet(isPresented: $model.showExport) {
            if let lesson = model.lesson { ExportSheet(model: model, lesson: lesson) }
        }
        .sheet(item: mainDraft) { draft in NewCourseSheet(model: model, draft: draft) }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }

    /// 就地新建课程的确认卡；从设置里发起的那一张出现在设置窗口上，不在这里。
    private var mainDraft: Binding<CourseDraft?> {
        Binding(get: { model.courseDraftInSettings ? nil : model.courseDraft }, set: { if $0 == nil { model.courseDraft = nil } })
    }

    /// 系统准备翻译资源时会弹出下载确认；会话只在此非隔离函数内使用，结果再交回主线程。
    private nonisolated func prepareTranslation(_ session: TranslationSession) async {
        let failure: String?
        do { try await session.prepareTranslation(); failure = nil } catch { failure = error.localizedDescription }
        await translationPrepared(failure)
    }

    private func translationPrepared(_ failure: String?) async {
        await model.finishTranslationPreparation(error: failure)
    }
}

/// 中间栏：有打开的课堂时显示字幕，否则显示开始页。
private struct LessonDetail: View {
    @Bindable var model: AppModel
    @State private var renaming = false
    @State private var titleDraft = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // 开始页与字幕页之间交叉淡入：点“开始听课”或切换课堂时不硬切。
            if model.lesson != nil { TranscriptScreen(model: model).transition(.opacity) }
            else { StartView(model: model).transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98))) }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.lesson?.id)
        .toolbar { MainToolbar(model: model) }
        .navigationTitle(model.lesson?.title ?? "LectoAI")
        .navigationSubtitle(subtitle)
        .toolbar {
            if model.lesson != nil {
                ToolbarTitleMenu {
                    Button("重命名…") { titleDraft = model.lesson?.title ?? ""; renaming = true }
                    if let lesson = model.lesson {
                        Menu("归到课程") { CourseMenuItems(model: model, lesson: lesson) }
                    }
                    Button("在 Finder 中显示") { model.reveal() }
                    Divider()
                    Button("关闭这堂课") { model.closeLesson() }.disabled(model.active)
                }
            }
        }
        .alert("重命名课堂", isPresented: $renaming) {
            TextField("课堂名称", text: $titleDraft)
            Button("保存") { model.rename(titleDraft) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("名称会用于课堂记录。已经交到课程文件夹的课堂，文件名不变。")
        }
    }

    private var subtitle: String {
        guard let lesson = model.lesson else { return "" }
        let time = lesson.createdAt.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute())
        // 归了课的课堂把课程名放在最前面，上课时一眼能看到这堂课会交到哪里。
        let date = [model.courseName(for: lesson), time].compactMap { $0 }.joined(separator: " · ")
        if model.isRecording || model.canResume { return date }
        return lesson.duration > 0 ? "\(date) · \(Format.duration(lesson.duration))" : date
    }
}

/// 工具栏：录音控制居中；右侧是阅读语言、导出、小窗与 AI 助手开关。
private struct MainToolbar: ToolbarContent {
    @Bindable var model: AppModel
    @AppStorage("readingMode") private var mode: ReadingMode = .bilingual

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            RecordingControls(model: model)
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("阅读语言", selection: $mode) {
                ForEach(ReadingMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("原文 / 双语 / 中文 / 总结（⌥⌘1 – ⌥⌘4）")
        }
        if model.lesson != nil, !model.isLive {
            ToolbarItem(placement: .primaryAction) { ExportMenu(model: model) }
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { model.floatingVisible }, set: { $0 ? model.showFloating() : model.hideFloating() })) {
                Label("小窗", systemImage: "pip")
            }
            .labelStyle(.titleAndIcon)
            .help("在其他 App 上方显示字幕小窗（⌘⇧F）")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $model.showAssistant) {
                Label("AI 助手", systemImage: "sparkles")
            }
            .labelStyle(.titleAndIcon)
            .help("显示或隐藏 AI 助手（⌥⌘0）")
        }
    }
}

/// 导出菜单：点按钮打开导出面板（勾选文件、命名、位置）；菜单里可按上次的选择直接导出到课程文件夹。
private struct ExportMenu: View {
    @Bindable var model: AppModel
    var body: some View {
        Menu {
            Button("导出…") { model.presentExport() }
            if let lesson = model.lesson, let course = model.courseName(for: lesson) {
                Button("交到“\(course)”") { model.requestHandoff(lesson.id, manual: true, delay: .zero) }
            }
            Divider()
            Button("在 Finder 中显示原始记录") { model.reveal() }
        } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        } primaryAction: {
            model.presentExport()
        }
        .disabled(model.active)
        .help("选择要导出的文件并命名（⇧⌘E）")
    }
}

/// 录音控制：开始（含音源选择）→ 录音状态/暂停/结束 → 已暂停/继续/结束；进行中的任务显示进度。
struct RecordingControls: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if model.preparingStart {
                ProgressView().controlSize(.small)
                Text(preparingText).font(.callout).foregroundStyle(.secondary)
            } else if model.repairing {
                ProgressView().controlSize(.small)
                Text("正在补识别").font(.callout)
                Button("停止") { model.cancelRepair() }
            } else if model.importing {
                ProgressView(value: model.importTotal > 0 ? min(1, model.elapsed / model.importTotal) : nil)
                    .frame(width: 90).controlSize(.small)
                Text("正在转写导入的录音 \(Format.clock(model.elapsed))").font(.callout).monospacedDigit()
                Button("停止") { Task { await model.finish() } }.disabled(model.busy)
            } else if model.busy {
                ProgressView().controlSize(.small)
                Text(model.lesson?.phase == .finishing ? "正在保存…" : "正在准备…").font(.callout).foregroundStyle(.secondary)
            } else if model.isRecording {
                HStack(spacing: 7) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(Format.clock(model.elapsed)).font(.body.monospacedDigit().weight(.medium))
                    LevelMeter(level: model.level)
                }
                .padding(.horizontal, 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("正在录音 \(Format.clock(model.elapsed))"))
                Button { Task { await model.finish(pausing: true) } } label: { Label("暂停", systemImage: "pause.fill") }
                    .help("暂停（⌘⇧R），继续后仍记在这堂课")
                Button { Task { await model.finish() } } label: { Label("结束", systemImage: "stop.fill") }
                    .help("结束并保存（⌘⇧S）")
            } else if model.canResume {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                    Text("已暂停 \(Format.clock(model.elapsed))").font(.body.monospacedDigit())
                }.padding(.horizontal, 6)
                SourceMenu(model: model, title: String(localized: "继续")) { Task { await model.start() } }
                Button { Task { await model.finish() } } label: { Label("结束", systemImage: "stop.fill") }
                    .help("结束并保存（⌘⇧S）")
            } else if model.lesson != nil {
                // 开始页正中已有大按钮；查看旧课时这里开始的是新的一堂，不会接着录这堂。
                SourceMenu(model: model, title: String(localized: "开始新课堂")) { Task { await model.startListening() } }
                    .disabled(model.updateSession)
            }
        }
        .labelStyle(.titleAndIcon)
        .fixedSize()
    }

    private var preparingText: String {
        if model.whisper.downloading { return String(localized: "正在下载离线语音模型 \(Int(model.whisper.progress * 100))%") }
        if let fraction = model.resources.downloadProgress?.fractionCompleted, fraction > 0 {
            return String(localized: "正在准备英语识别 \(Int(fraction * 100))%")
        }
        return String(localized: "正在准备英语识别…")
    }
}

/// 带音源下拉的主按钮：点按钮直接开始，下拉选择麦克风或电脑声音。
struct SourceMenu: View {
    @Bindable var model: AppModel
    let title: String
    let action: () -> Void
    var body: some View {
        Menu {
            Picker("音源", selection: $model.sourceSystem) {
                Label("麦克风（现场上课）", systemImage: "mic").tag(false)
                Label("电脑声音（网课、视频）", systemImage: "speaker.wave.2").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Label(title, systemImage: model.sourceSystem ? "speaker.wave.2.fill" : "mic.fill")
        } primaryAction: {
            action()
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .help(model.sourceSystem ? "音源：电脑声音。点箭头切换" : "音源：麦克风。点箭头切换")
        .accessibilityIdentifier("startClassroom")
    }
}
