import AppKit
import LectoAICore
import Observation
import SwiftUI

/// 小窗的界面状态：悬停、记一笔输入、结束确认、标记反馈。
@MainActor @Observable
final class FloatingPanelState {
    var hovering = false
    var typing = false
    var confirmEnd = false
    var flash: String?
}

/// 字幕小窗：不激活 App 的浮动面板，可叠在全屏课件上；只有记一笔时临时接收键盘输入。
@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    weak var model: AppModel?
    let state = FloatingPanelState()
    private var panel: CaptionPanel?

    func show() {
        guard let model else { return }
        if panel == nil {
            let panel = CaptionPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 190),
                                     styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                panel.standardWindowButton(button)?.isHidden = true
            }
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.isRestorable = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.minSize = NSSize(width: 380, height: 120)
            panel.title = String(localized: "LectoAI 字幕小窗")
            panel.setAccessibilityIdentifier("captionPanel")
            panel.delegate = self
            let host = CaptionHostingView(rootView: FloatingCaptionView(model: model, state: state, controller: self))
            host.onHover = { [weak self] inside in self?.state.hovering = inside }
            // 托管视图放进普通容器：窗口大小只由用户拖放决定，不随字幕内容增长或反复重算。
            host.sizingOptions = []
            let container = NSView(frame: NSRect(origin: .zero, size: panel.contentRect(forFrameRect: panel.frame).size))
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            panel.contentView = container
            // 首次出现在主屏幕下方居中；之后记住用户拖放的位置与大小。
            if !panel.setFrameUsingName("LectoAICaptionPanel"), let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.midX - 320, y: screen.minY + 48))
            }
            panel.setFrameAutosaveName("LectoAICaptionPanel")
            self.panel = panel
        }
        applyPreferences()
        ensureVisibleOnScreen()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo-hover") { state.hovering = true }
        #endif
        panel?.orderFrontRegardless()
        model.floatingVisible = true
    }

    /// 置顶与深浅色：置顶时浮在所有窗口（含全屏 App）之上；取消置顶后像普通窗口一样可被遮住。
    func applyPreferences() {
        guard let panel else { return }
        let pinned = UserDefaults.standard.object(forKey: "floatingPinned") == nil || UserDefaults.standard.bool(forKey: "floatingPinned")
        // 比“主窗口保持在最前”（.floating）再高一层，主窗口置顶时也不会盖住小窗。
        panel.level = pinned ? NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1) : .normal
        #if DEBUG
        // 界面测试的主窗口被置顶（--demo-front）；小窗无论是否钉住都保持在它之上，测试才能点到。
        if ProcessInfo.processInfo.arguments.contains("--demo-front") { panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1) }
        #endif
        panel.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle] : [.managed, .ignoresCycle]
        let light = UserDefaults.standard.string(forKey: "floatingTheme") == "light"
        panel.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    }

    func hide() {
        endTyping()
        panel?.orderOut(nil)
        model?.floatingVisible = false
    }

    /// 记一笔：让面板临时成为键盘窗口；不激活 App，课件/笔记仍在前台。
    func beginTyping() {
        state.typing = true
        panel?.allowsKey = true
        panel?.makeKey()
    }

    func endTyping() {
        state.typing = false
        panel?.allowsKey = false
    }

    /// 显示器断开或分辨率变化后，把小窗移回可见区域。
    private func ensureVisibleOnScreen() {
        guard let panel else { return }
        let frame = panel.frame
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return }
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - frame.width / 2, y: screen.minY + 48))
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if state.typing { endTyping() }
    }
}

final class CaptionPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// 悬停检测用 activeAlways 跟踪区域：App 不在前台时也能显示小窗控件；首次点击直接生效。
final class CaptionHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 小窗显示内容：三种字幕、AI 续写的课堂总结，或 AI 整理的课堂纪要（同传不合适时直接看要点）。
enum FloatingMode: String, CaseIterable, Identifiable {
    case original, bilingual, chinese, summary, digest
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .original: "原文"
        case .bilingual: "双语"
        case .chinese: "中文"
        case .summary: "总结"
        case .digest: "纪要"
        }
    }
    var reading: ReadingMode {
        switch self {
        case .original: .original
        case .chinese: .chinese
        default: .bilingual
        }
    }
}

/// 小窗内容：状态行 + 可上下滚动的字幕（或总结、纪要），默认停在最新；控件只在悬停时出现，平时只留内容。
struct FloatingCaptionView: View {
    @Bindable var model: AppModel
    @Bindable var state: FloatingPanelState
    let controller: FloatingPanelController
    @AppStorage("floatingReadingMode") private var mode: FloatingMode = .bilingual
    @AppStorage("floatingScale") private var scale = 1.0
    @AppStorage("floatingTheme") private var theme = "dark"
    @AppStorage("floatingPinned") private var pinned = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var light: Bool { theme == "light" }
    /// 正文颜色：深色面板用白字，浅色面板用黑字。
    private var ink: Color { light ? .black : .white }

    var body: some View {
        ZStack {
            VisualEffectBackground(material: light ? .popover : .hudWindow).ignoresSafeArea()
            (light ? Color.white.opacity(0.55) : Color.black.opacity(0.42)).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 6) {
                header
                if state.typing { FloatingNoteField(model: model, controller: controller, ink: ink) }
                switch mode {
                case .digest: FloatingDigest(model: model, scale: scale, ink: ink)
                case .summary: FloatingSummary(model: model, scale: scale, ink: ink)
                default: captions
                }
            }
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 14)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, light ? .light : .dark)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: state.hovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.typing)
        .onChange(of: theme) { _, _ in controller.applyPreferences() }
        .onChange(of: pinned) { _, _ in controller.applyPreferences() }
    }

    // MARK: 状态行

    private var header: some View {
        HStack(spacing: 8) {
            status
            if let flash = state.flash {
                Label(flash, systemImage: "checkmark").font(.caption.weight(.medium)).foregroundStyle(.green)
                    .transition(.opacity)
            } else if mode != .digest, let topic = model.lesson?.focus?.topic ?? model.lesson?.structuredInsight?.topic, model.isLive {
                Text(topic).font(.caption).foregroundStyle(ink.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 8)
            if state.hovering || state.typing || state.confirmEnd { controls.transition(.opacity) }
        }
        .frame(height: 26)
    }

    @ViewBuilder private var status: some View {
        if model.importing {
            Label("正在转写导入的录音 \(Format.clock(model.elapsed))", systemImage: "waveform")
                .font(.caption.monospacedDigit()).foregroundStyle(ink.opacity(0.7))
        } else if model.isRecording {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Text(Format.clock(model.elapsed)).font(.caption.monospacedDigit().weight(.medium))
            }
            .foregroundStyle(ink.opacity(0.85))
            .accessibilityLabel(Text("正在录音 \(Format.clock(model.elapsed))"))
        } else if model.canResume {
            Label("已暂停 \(Format.clock(model.elapsed))", systemImage: "pause.fill")
                .font(.caption.monospacedDigit()).foregroundStyle(.orange)
        } else if model.busy {
            Text(model.lesson?.phase == .finishing ? "正在保存…" : "正在准备…").font(.caption).foregroundStyle(ink.opacity(0.7))
        } else {
            Text("LectoAI").font(.caption.weight(.semibold)).foregroundStyle(ink.opacity(0.6))
        }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            if model.isLive {
                iconButton("questionmark.circle", tint: .orange, help: "标记没听懂") { mark(.confused) }
                    .accessibilityIdentifier("floatingMarkConfused")
                iconButton("star", tint: .yellow, help: "标记重点") { mark(.important) }
                iconButton("square.and.pencil", help: "记一笔") { controller.beginTyping() }
                    .disabled(state.typing)
                Divider().frame(height: 16).padding(.horizontal, 4)
                if model.isRecording {
                    iconButton("pause.fill", help: "暂停") { Task { await model.finish(pausing: true) } }
                } else {
                    iconButton("play.fill", help: "继续") { Task { await model.start() } }
                }
                if state.confirmEnd {
                    Button("结束并保存") { state.confirmEnd = false; Task { await model.finish() } }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                        .task { try? await Task.sleep(for: .seconds(3)); state.confirmEnd = false }
                } else {
                    iconButton("stop.fill", help: "结束这堂课") { state.confirmEnd = true }
                }
                Divider().frame(height: 16).padding(.horizontal, 4)
            }
            iconButton(pinned ? "pin.fill" : "pin.slash", tint: pinned ? .accentColor : ink, help: pinned ? "已置顶：浮在所有窗口之上。点击取消置顶" : "未置顶：点击让小窗浮在所有窗口之上") {
                pinned.toggle()
            }
            .accessibilityIdentifier("floatingPin")
            .accessibilityValue(pinned ? "已置顶" : "未置顶")
            Menu {
                Picker("显示", selection: $mode) {
                    ForEach(FloatingMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("外观", selection: $theme) {
                    Text("深色").tag("dark")
                    Text("浅色").tag("light")
                }
                .pickerStyle(.inline)
                Divider()
                Button("放大文字") { scale = CaptionScale.larger(scale) }
                Button("缩小文字") { scale = CaptionScale.smaller(scale) }
                Divider()
                Button("打开主窗口") { model.presentMain?() }
                Button("隐藏小窗") { controller.hide() }
            } label: { Image(systemName: "ellipsis.circle").foregroundStyle(ink.opacity(0.9)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("显示内容、外观与更多")
            iconButton("xmark", help: "隐藏小窗") { controller.hide() }
        }
        .disabled(model.busy)
    }

    private func iconButton(_ symbol: String, tint: Color? = nil, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle((tint ?? ink).opacity(0.9)).frame(width: 24, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func mark(_ kind: NoteMark) {
        model.mark(kind)
        let label = kind == .confused ? String(localized: "已标记没听懂") : String(localized: "已标记重点")
        withAnimation { state.flash = label }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if state.flash == label { withAnimation { state.flash = nil } }
        }
    }

    // MARK: 字幕

    @ViewBuilder private var captions: some View {
        if let lesson = model.lesson, !lesson.lines.isEmpty || model.isRecording {
            FloatingCaptions(model: model, lesson: lesson, mode: mode.reading, scale: scale, ink: ink)
        } else {
            idle
        }
    }

    private var idle: some View {
        VStack(spacing: 10) {
            Text(model.lesson == nil ? "还没有开始听课" : "这堂课已结束").font(.callout).foregroundStyle(ink.opacity(0.6))
            if !model.active {
                Button { Task { await model.startListening() } } label: {
                    Label("开始听课", systemImage: model.sourceSystem ? "speaker.wave.2.fill" : "mic.fill")
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(model.preparingStart || model.updateSession)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 顶部淡出遮罩：跟随最新时旧内容向上淡出；往上翻看时取消淡出，整屏都清楚。
private struct FadeTop: View {
    var active = true
    var body: some View {
        LinearGradient(stops: [.init(color: active ? .clear : .black, location: 0), .init(color: .black, location: 0.22), .init(color: .black, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// 小窗的滚动区：默认停在最新（底部），内容不满一屏时贴底；往上滚查看之前的内容时暂停跟随，
/// 滚回底部或点“最新”恢复。ScrollView 会裁剪点击区域，越界文字不再挡住顶部按钮（0.3.3 问题）。
/// content 收到 follow：内容在不改变 key 的情况下变长（临时文字）时调用，跟随中就贴到底部。
private struct FloatingScroll<Content: View, Key: Equatable>: View {
    let ink: Color
    let key: Key
    @ViewBuilder let content: (_ follow: @escaping () -> Void) -> Content
    @State private var following = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let bottomID = "floating-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            let follow = { if following { proxy.scrollTo(bottomID, anchor: .bottom) } }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content(follow)
                    Color.clear.frame(height: 2).id(bottomID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 小窗可从文字处拖动（滚动用触控板/滚轮，不冲突）。
                .gesture(WindowDragGesture())
            }
            .scrollIndicators(.automatic)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .onScrollPhaseChange { old, new, context in
                // 与主窗口相同：只在用户滚动时改变跟随状态；不用 onScrollGeometryChange（缩放时会引发约束死循环）。
                if new == .interacting { following = false }
                if new == .idle, old != .idle {
                    let geometry = context.geometry
                    following = geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 30
                }
            }
            .onChange(of: key) { _, _ in follow() }
            .mask(FadeTop(active: following))
            .overlay(alignment: .bottomTrailing) {
                if !following {
                    Button {
                        following = true
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                    } label: {
                        Label("最新", systemImage: "arrow.down").font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .accessibilityLabel(Text("回到最新"))
                    .accessibilityIdentifier("floatingLatest")
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: following)
        }
    }
}

/// 字幕：整堂课的段落都在，可往上翻；进行中的临时文字放在单独的视图里，刷新时不重算整张列表。
private struct FloatingCaptions: View {
    @Bindable var model: AppModel
    let lesson: Lesson
    let mode: ReadingMode
    let scale: Double
    let ink: Color

    var body: some View {
        let paragraphs = TranscriptLayout.items(for: lesson).compactMap { item -> DisplayParagraph? in
            if case .paragraph(let value) = item { value } else { nil }
        }
        FloatingScroll(ink: ink, key: lesson.sequence) { follow in
            LazyVStack(alignment: .leading, spacing: 10 * scale) {
                ForEach(paragraphs) { FloatingParagraph(model: model, paragraph: $0, mode: mode, scale: scale, ink: ink) }
                FloatingLiveTail(model: model, last: paragraphs.last, mode: mode, scale: scale, ink: ink, follow: follow)
            }
        }
    }
}

/// 字幕末尾：另起一段的临时文字（或“正在聆听”）；临时文字变长时让列表继续贴底。
private struct FloatingLiveTail: View {
    @Bindable var model: AppModel
    let last: DisplayParagraph?
    let mode: ReadingMode
    let scale: Double
    let ink: Color
    let follow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            if model.isRecording, !model.partial.isEmpty, model.partialStartsNewParagraph(after: last) {
                if mode.showsEnglish {
                    Text(model.partial).font(.system(size: 19 * scale, weight: .medium)).foregroundStyle(ink.opacity(0.55))
                }
                if mode.showsChinese {
                    Text(model.partialTranslation.isEmpty ? "…" : model.partialTranslation)
                        .font(.system(size: (mode == .chinese ? 20 : 17) * scale)).foregroundStyle(ink.opacity(0.45))
                }
            }
            if last == nil, model.partial.isEmpty {
                Text("正在聆听…").font(.system(size: 17 * scale)).foregroundStyle(ink.opacity(0.5))
            }
        }
        .onChange(of: model.partial) { _, _ in follow() }
        .onChange(of: model.partialTranslation) { _, _ in follow() }
    }
}

/// 小窗的总结模式：与主窗口“总结”页同一篇文章，每段前是课堂时间；约 1.5–2 分钟多一段。
private struct FloatingSummary: View {
    @Bindable var model: AppModel
    let scale: Double
    let ink: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let article = model.lesson?.article ?? []
        // 已有的总结总是显示（例如回看旧课时没连接 AI）；没有内容时才提示。
        if article.isEmpty, !model.aiConfigured {
            FloatingMessage(text: "连接 AI 后，这里会随课堂进度续写中文总结。在主窗口右侧的 AI 助手里连接。", ink: ink)
        } else if article.isEmpty {
            FloatingMessage(text: model.articleBusy ? "正在写第一段总结…"
                            : model.isLive ? "上课约 1–2 分钟后，这里会出现第一段总结。" : "这堂课还没有总结，可在主窗口“总结”页生成。", ink: ink)
        } else {
            FloatingScroll(ink: ink, key: [article.count, model.articleBusy ? 1 : 0]) { _ in
                LazyVStack(alignment: .leading, spacing: 12 * scale) {
                    ForEach(article) { paragraph in
                        (Text(Format.clock(paragraph.start) + "  ").font(.system(size: 12 * scale).monospacedDigit()).foregroundStyle(ink.opacity(0.45))
                         + Text(paragraph.text).font(.system(size: 17 * scale)).foregroundStyle(ink.opacity(0.92)))
                            .lineSpacing(4 * scale)
                            .transition(.opacity)
                    }
                    if model.articleBusy {
                        Text("正在续写…").font(.system(size: 13 * scale)).foregroundStyle(ink.opacity(0.45))
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: article.count)
            }
        }
    }
}

/// 小窗的纪要模式：各节标题与要点按时间排列，最新一节在底部；此刻提示接在最后。
private struct FloatingDigest: View {
    @Bindable var model: AppModel
    let scale: Double
    let ink: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let sections = model.lesson?.digest ?? []
        if sections.isEmpty, !model.aiConfigured {
            FloatingMessage(text: "连接 AI 后，这里会显示课堂纪要。在主窗口右侧的 AI 助手里连接。", ink: ink)
        } else if sections.isEmpty {
            FloatingMessage(text: model.digestBusy ? "正在整理纪要…" : "上课约 2 分钟后，这里会出现第一节纪要。", ink: ink)
        } else {
            FloatingScroll(ink: ink, key: model.lesson?.sequence ?? 0) { _ in
                LazyVStack(alignment: .leading, spacing: 14 * scale) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 6 * scale) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(section.title).font(.system(size: 17 * scale, weight: .semibold)).foregroundStyle(ink)
                                    .contentTransition(.opacity)
                                Text("\(Format.clock(section.start))–\(Format.clock(section.end))")
                                    .font(.system(size: 12 * scale).monospacedDigit()).foregroundStyle(ink.opacity(0.45))
                            }
                            ForEach(Array(section.points.enumerated()), id: \.offset) { _, point in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    KindTag(kind: point.kind).scaleEffect(scale, anchor: .leading)
                                    Text(point.text).font(.system(size: 16 * scale)).foregroundStyle(ink.opacity(0.88))
                                        .contentTransition(.opacity)
                                }
                            }
                        }
                    }
                    if let focus = model.lesson?.focus, model.isLive, !focus.hint.isEmpty {
                        Label(focus.hint, systemImage: "location.fill")
                            .font(.system(size: 14 * scale)).foregroundStyle(Color.accentColor)
                            .contentTransition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: sections)
            }
        }
    }
}

/// 小窗内容区的提示文字（未连接 AI、还没有内容等）。
private struct FloatingMessage: View {
    let text: LocalizedStringKey
    let ink: Color
    var body: some View {
        Text(text).font(.callout).foregroundStyle(ink.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .multilineTextAlignment(.center)
    }
}

/// 小窗中的一段：英文在上、中文在下；进行中的段落接浅色临时文字。
private struct FloatingParagraph: View {
    @Bindable var model: AppModel
    let paragraph: DisplayParagraph
    let mode: ReadingMode
    let scale: Double
    let ink: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            if mode.showsEnglish {
                english.font(.system(size: 19 * scale, weight: .medium)).lineSpacing(2 * scale)
            }
            if mode.showsChinese, let chinese = chinese {
                chinese.font(.system(size: (mode == .chinese ? 20 : 17) * scale)).lineSpacing(3 * scale)
            }
        }
    }

    private var english: Text {
        var text = Text(paragraph.english).foregroundStyle(ink)
        if speakingHere {
            text = text + Text(" " + model.partial).foregroundStyle(ink.opacity(0.5))
        }
        return text
    }

    private var chinese: Text? {
        let primary = mode == .chinese
        let color: Color = primary ? ink : ink.opacity(0.78)
        switch paragraph.chinese {
        case .polished(let text): return Text(text).foregroundStyle(color)
        case .draft(let pieces):
            let pending = pieces.contains { $0 == nil } || speakingHere
            return Text(pieces.compactMap { $0 }.joined()).foregroundStyle(color) + (pending ? tentative : Text(""))
        case .none:
            return paragraph.isOpen ? tentative : (primary ? Text(paragraph.english).foregroundStyle(ink.opacity(0.45)) : nil)
        }
    }

    private var speakingHere: Bool {
        paragraph.isOpen && !model.partial.isEmpty && !model.partialStartsNewParagraph(after: paragraph)
    }

    /// 仍在翻译的部分：有临时译文就淡色显示，否则“…”。
    private var tentative: Text {
        if speakingHere, !model.partialTranslation.isEmpty { return Text(model.partialTranslation).foregroundStyle(ink.opacity(0.45)) }
        return Text(" …").foregroundStyle(ink.opacity(0.4))
    }
}

/// 小窗里的记一笔：回车保存、Esc 取消；锚定点开输入框的时刻。
private struct FloatingNoteField: View {
    @Bindable var model: AppModel
    let controller: FloatingPanelController
    let ink: Color
    @State private var text = ""
    @State private var anchor: NoteAnchor?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let time = anchor?.time {
                Text(Format.clock(time)).font(.caption.monospacedDigit()).foregroundStyle(ink.opacity(0.7))
            }
            TextField("记一笔，回车保存，Esc 取消", text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(ink)
                .focused($focused)
                .onSubmit {
                    if let anchor { model.addNote(text: text, anchor: anchor) }
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty { controller.state.flash = String(localized: "已记下") }
                    text = ""; controller.endTyping()
                    Task { try? await Task.sleep(for: .seconds(1.6)); controller.state.flash = nil }
                }
                .onExitCommand { text = ""; controller.endTyping() }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(ink.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear { anchor = model.currentAnchor(); focused = true }
    }
}
