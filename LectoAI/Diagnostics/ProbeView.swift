#if DEBUG
import AppKit
import SwiftUI
import Translation

struct ProbeView: View {
    @State private var audio = AudioProbe()
    @State private var resources = ResourceProbe()
    @State private var floating = ProbePanelController()
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var translationBusy = false
    @State private var translationResult = ""

    var body: some View {
        Form {
            Section("音频试音") {
                Text("只显示电平，15 秒后自动停止，不保存录音。系统音频试音期间，请在浏览器播放一段视频。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("麦克风试音") { Task { await audio.startMicrophone() } }
                    Button("系统音频试音") { audio.startSystemAudio() }
                }.disabled(audio.running || audio.starting)
                HStack {
                    ProgressView(value: audio.level.normalized).frame(width: 220)
                    Text(audio.source)
                    Spacer()
                    Button("停止试音") { audio.stop() }.disabled(!audio.running && !audio.starting)
                }
                Text(audio.message).font(.callout).accessibilityIdentifier("audioProbeStatus")
            }
            Section("本地语言资源") {
                LabeledContent("英语转写", value: resources.speech)
                LabeledContent("英译中", value: resources.translation)
                HStack {
                    Button("重新检查") { Task { await resources.refresh() } }
                        .disabled(resources.checking || resources.downloading || translationBusy)
                    Button("下载识别资源") { resources.downloadSpeech() }
                        .disabled(!resources.speechCanDownload || resources.downloading || resources.checking)
                    if resources.downloading {
                        Button("取消等待") { resources.cancelDownload() }
                    }
                }
                if resources.downloading {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        ProgressView(value: resources.downloadProgress?.fractionCompleted ?? 0)
                    }
                }
                HStack {
                    Button("准备翻译并试译") {
                        translationBusy = true
                        translationResult = "等待系统准备语言资源…"
                        if translationConfiguration == nil {
                            translationConfiguration = .init(source: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))
                        } else { translationConfiguration?.invalidate() }
                    }
                    .disabled(!resources.translationSupported || translationBusy || resources.checking)
                    if translationBusy {
                        Button("取消翻译") { translationConfiguration = nil; translationBusy = false; translationResult = "已取消" }
                    }
                }
                Text(translationResult.isEmpty ? "试译内容：A good algorithm needs a proof." : translationResult)
                    .font(.callout).textSelection(.enabled)
            }
            Section("浮窗验证") {
                HStack {
                    Button("显示测试浮窗") { floating.show(audio: audio) }
                    Button("隐藏测试浮窗") { floating.hide() }
                }
                Text("显示后切到全屏浏览器或 Keynote：确认浮窗可见、原应用仍能接收键盘输入。浮窗显示同一份试音状态，不启动新的音源。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("这是功能验证工具；尚未接入课堂录音保存和实时字幕。")
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped).frame(minWidth: 680, minHeight: 660)
        .task { await resources.refresh() }
        .translationTask(translationConfiguration, action: runTranslation)
        .onDisappear {
            audio.stop()
            resources.cancelDownload()
            translationConfiguration = nil
            floating.hide()
        }
    }

    /// 会话留在非隔离异步上下文中，仅把可发送的文本结果交回主线程。
    private nonisolated func runTranslation(_ session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            try Task.checkCancellation()
            let response = try await session.translate("A good algorithm needs a proof.")
            try Task.checkCancellation()
            await finishTranslation(response.targetText)
        } catch is CancellationError {
            // 取消后的旧任务不能覆盖新请求或关闭后的状态。
        } catch {
            guard !Task.isCancelled else { return }
            await finishTranslation("翻译准备失败：\(error.localizedDescription)")
        }
    }

    private func finishTranslation(_ result: String) async {
        translationResult = result
        translationBusy = false
        await resources.refresh()
    }
}

@MainActor
private final class ProbePanelController {
    private var panel: NSPanel?

    func show(audio: AudioProbe) {
        if let panel { panel.orderFrontRegardless(); return }
        let panel = PassiveProbePanel(contentRect: NSRect(x: 160, y: 160, width: 360, height: 130),
                                     styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        panel.title = "LectoAI 浮窗测试"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            Label("浮窗测试", systemImage: "rectangle.on.rectangle")
            ProbePanelMeter(audio: audio)
        }.padding(22).frame(width: 360, height: 130).background(.regularMaterial))
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

private struct ProbePanelMeter: View {
    var audio: AudioProbe
    var body: some View {
        VStack(alignment: .leading) {
            Text(audio.running ? "试音中 · \(audio.source)" : "未在采集")
            ProgressView(value: audio.level.normalized)
        }
    }
}

private final class PassiveProbePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
#endif
