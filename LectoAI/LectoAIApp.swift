import AppKit
import SwiftUI

@main
struct LectoAIApp: App {
    @NSApplicationDelegateAdaptor(LectoDelegate.self) private var delegate
    private var model: AppModel { delegate.model }

    init() {
        // 窗口位置与大小由 frame autosave 记忆，不使用系统窗口恢复；
        // 否则一次异常退出后，下次启动会被“是否重新打开窗口”的系统提示挡住。
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "showAssistant": true, "autoDigest": true,
                                                  "floatingPinned": true, "floatingTheme": "dark", "mainPinned": false,
                                                  "keepScreenOn": true])
    }

    var body: some Scene {
        #if DEBUG
        Window("本机能力检查", id: "probes") {
            ProbeView()
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 720, height: 760)
        .commands { ProbeCommands() }
        #endif
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" : model.canResume ? "pause.circle" : "waveform")
        }
        Settings { SettingsView(model: model) }
            .commands { ClassroomCommands(model: model) }
    }
}

#if DEBUG
private struct ProbeCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandMenu("开发") {
            Button("本机能力检查…") { openWindow(id: "probes") }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}
#endif

/// 菜单栏图标：主窗口和小窗都隐藏时，仍能看到录音状态并开始/暂停/结束。
private struct MenuContent: View {
    @Bindable var model: AppModel
    var body: some View {
        if model.isRecording {
            Text("● 录音中 \(Format.clock(model.elapsed))")
            Button("暂停") { Task { await model.finish(pausing: true) } }.disabled(model.busy)
            Button("结束并保存") { Task { await model.finish() } }.disabled(model.busy)
        } else if model.canResume {
            Text("已暂停 \(Format.clock(model.elapsed))")
            Button("继续") { Task { await model.start() } }.disabled(model.busy)
            Button("结束并保存") { Task { await model.finish() } }.disabled(model.busy)
        } else {
            Button("开始听课") { Task { await model.startListening() } }.disabled(model.active || model.preparingStart)
        }
        Divider()
        Toggle("字幕小窗", isOn: Binding(get: { model.floatingVisible }, set: { $0 ? model.showFloating() : model.hideFloating() }))
        Button("打开 LectoAI") {
            model.presentMain?()
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出 LectoAI") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
private final class LectoDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var workspace: NSWindow?
    private var preferenceObserver: NSObjectProtocol?
    private var updates: UpdateController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        updates = UpdateController(model: model)
        model.checkUpdates = { [weak self] in self?.updates?.check() }
        model.presentMain = { [weak self] in self?.showWorkspace() }
        showWorkspace()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo-floating") { model.showFloating() }
        #endif
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWorkspace()
        return true
    }
    private func showWorkspace() {
        if let workspace { workspace.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let controller = NSHostingController(rootView: MainView(model: model))
        // 让 SwiftUI 的工具栏、标题、侧栏与检查器接入 AppKit 管理的主窗口。
        controller.sceneBridgingOptions = [.toolbars, .title]
        // 窗口最小尺寸固定由 AppKit 管理，不随 SwiftUI 内容反复重算。
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.title = "LectoAI"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1240, height: 800))
        window.minSize = NSSize(width: 660, height: 480)
        window.identifier = NSUserInterfaceItemIdentifier("LectoAIMainWindow")
        // 位置与大小由 frame autosave 记忆；不参与系统窗口恢复，避免异常退出后启动被恢复提示阻塞。
        window.isRestorable = false
        window.delegate = self
        workspace = window
        // 恢复上次的位置与大小；记录异常（过小）时回到默认大小并居中。
        if !window.setFrameUsingName("LectoAIMainWindow") || window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            window.setContentSize(NSSize(width: 1240, height: 800))
            window.center()
        }
        window.setFrameAutosaveName("LectoAIMainWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        applyPinning()
        // 设置或菜单里切换“置顶”后立即生效。
        preferenceObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPinning() }
        }
        #if DEBUG
        // 截图自查用：让主窗口保持在最前，不受台前调度收起影响。
        if ProcessInfo.processInfo.arguments.contains("--demo-front") {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        // 缩放回归测试：逐步把窗口缩到最小再放大，复现拖窄窗口时的布局问题。
        if ProcessInfo.processInfo.arguments.contains("--demo-shrink") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                // 先缩到最小尺寸并停留，记录布局稳定后的实际大小，再放大回去。
                let steps = Array(stride(from: 0.0, through: 1.0, by: 0.02))
                for t in steps + [1, 1] + steps.reversed() {
                    var frame = window.frame
                    frame.size = NSSize(width: 1240 - (1240 - window.minSize.width) * t, height: 800 - (800 - window.minSize.height) * t)
                    window.setFrame(frame, display: true)
                    try? await Task.sleep(for: .milliseconds(t == 1 ? 1500 : 40))
                    NSLog("demo-shrink size %.0f x %.0f", window.frame.width, window.frame.height)
                }
                NSLog("demo-shrink done")
            }
        }
        #endif
    }
    /// 主窗口置顶（默认关闭）与小窗置顶/外观。
    private func applyPinning() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo-front") { return }
        #endif
        let pinned = UserDefaults.standard.bool(forKey: "mainPinned")
        workspace?.level = pinned ? .floating : .normal
        model.floating.applyPreferences()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            model.cancelRepair()
            while model.busy || model.repairing { try? await Task.sleep(for: .milliseconds(100)) }
            await model.finish()
            // 结束时排进队里的交接做完再退出（有上限）；做不完的下次启动补交。
            await model.drainHandoffs()
            await model.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// 菜单与快捷键：文件、课堂、显示三类，与工具栏一致。
private struct ClassroomCommands: Commands {
    @Bindable var model: AppModel
    @AppStorage("readingMode") private var mode: ReadingMode = .bilingual
    @AppStorage("captionScale") private var scale = 1.0
    @AppStorage("mainPinned") private var mainPinned = false

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") { model.checkUpdates?() }.disabled(model.active)
        }
        CommandGroup(replacing: .newItem) {
            Button("导入录音…") { model.chooseFile() }.keyboardShortcut("o").disabled(model.active)
            Button("导出…") { model.presentExport() }.keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.active || model.lesson == nil)
            Button("在 Finder 中显示") { model.reveal() }.disabled(model.lesson == nil)
        }
        CommandMenu("课堂") {
            Button(model.isRecording ? "暂停" : model.canResume ? "继续" : "开始听课") {
                Task {
                    if model.isRecording { await model.finish(pausing: true) }
                    else if model.canResume { await model.start() }
                    else { await model.startListening() }
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.busy || model.importing || model.repairing || model.updateSession || model.preparingStart)
            Button("结束并保存") { Task { await model.finish() } }.keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!model.isRecording && !model.canResume)
            Divider()
            Button("标记没听懂") { model.mark(.confused) }.keyboardShortcut("u", modifiers: [.command, .shift]).disabled(!model.isLive)
            Button("标记重点") { model.mark(.important) }.keyboardShortcut("i", modifiers: [.command, .shift]).disabled(!model.isLive)
            Button("记一笔") { model.presentMain?(); model.composerFocusRequest += 1 }
                .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!model.isLive)
            Divider()
            Button("问 AI…") { model.presentMain?(); model.showAssistant = true; model.questionFocusRequest += 1 }
                .keyboardShortcut("a", modifiers: [.command, .shift]).disabled(model.lesson == nil)
            Button("补识别缺口") { model.repairGaps() }
                .disabled(model.active || (model.lesson?.gaps ?? []).allSatisfy { $0.resolved })
            if let lesson = model.lesson {
                Divider()
                Menu("归到课程") { CourseMenuItems(model: model, lesson: lesson) }
            }
        }
        CommandGroup(after: .toolbar) {
            Picker("阅读语言", selection: $mode) {
                Text("原文").tag(ReadingMode.original).keyboardShortcut("1", modifiers: [.command, .option])
                Text("双语").tag(ReadingMode.bilingual).keyboardShortcut("2", modifiers: [.command, .option])
                Text("中文").tag(ReadingMode.chinese).keyboardShortcut("3", modifiers: [.command, .option])
                Text("总结").tag(ReadingMode.summary).keyboardShortcut("4", modifiers: [.command, .option])
            }
            .pickerStyle(.inline)
            Divider()
            Button("放大字幕") { scale = CaptionScale.larger(scale) }.keyboardShortcut("+")
            Button("缩小字幕") { scale = CaptionScale.smaller(scale) }.keyboardShortcut("-")
            Button("默认字号") { scale = 1 }.keyboardShortcut("0")
            Divider()
            Button(model.floatingVisible ? "隐藏字幕小窗" : "显示字幕小窗") { model.toggleFloating() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button(model.showAssistant ? "隐藏 AI 助手" : "显示 AI 助手") { model.showAssistant.toggle() }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Toggle("主窗口保持在最前", isOn: $mainPinned)
        }
        #if DEBUG
        CommandMenu("识别调试") {
            Toggle("强制使用 Whisper", isOn: Binding(get: { UserDefaults.standard.bool(forKey: "forceWhisper") }, set: { UserDefaults.standard.set($0, forKey: "forceWhisper") })).disabled(model.active)
        }
        #endif
    }
}
