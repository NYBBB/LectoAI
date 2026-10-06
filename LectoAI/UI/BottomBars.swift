import AppKit
import LectoAICore
import SwiftUI

/// 课上底部栏：一键标记“没听懂/重点”，或边看字幕边记一笔（回车保存）。
struct Composer: View {
    @Bindable var model: AppModel
    @State private var text = ""
    @State private var anchor: NoteAnchor?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            markButton(.confused, title: "没听懂", help: "标记此刻没听懂（⌘⇧U），课后可让 AI 逐条解释")
            markButton(.important, title: "重点", help: "标记此刻是重点（⌘⇧I）")
            Divider().frame(height: 20)
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").foregroundStyle(.secondary)
                if let time = anchor?.time {
                    Text(Format.clock(time))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .help("这条笔记会记在这个时刻")
                        .transition(.opacity)
                }
                TextField("记一笔…（回车保存）", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onChange(of: text) { _, value in
                        // 开始输入的那一刻锁定时间与引用，之后字幕继续滚动也不改变。
                        if anchor == nil, !value.trimmingCharacters(in: .whitespaces).isEmpty { anchor = model.currentAnchor() }
                        if value.isEmpty { anchor = nil }
                    }
                    .onSubmit { save() }
                    .onExitCommand { text = ""; anchor = nil; focused = false }
                    .accessibilityIdentifier("noteComposer")
                if !text.isEmpty {
                    Button { save() } label: { Image(systemName: "return") }
                        .buttonStyle(.borderless).help("保存（回车）")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(focused ? 0.06 : 0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .frame(maxWidth: 820)
        .padding(.horizontal, 20).padding(.bottom, 14).padding(.top, 6)
        .animation(.easeOut(duration: 0.15), value: anchor?.time)
        .onChange(of: model.composerFocusRequest) { _, _ in focused = true }
    }

    private func markButton(_ mark: NoteMark, title: LocalizedStringKey, help: LocalizedStringKey) -> some View {
        let style = NoteStyle(mark)
        return Button { model.mark(mark) } label: {
            Label(title, systemImage: style.icon)
                .foregroundStyle(mark == .important ? Color.orange : style.color)
        }
        .buttonStyle(.bordered)
        .help(help)
        .accessibilityIdentifier(mark == .confused ? "markConfused" : "markImportant")
    }

    private func save() {
        guard let anchor = anchor ?? model.currentAnchor() else { return }
        let saved = text
        model.addNote(text: saved, anchor: anchor)
        if !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.toast = Toast(text: String(localized: "已记下 · \(Format.clock(anchor.time ?? anchor.line?.start ?? 0))"))
        }
        text = ""; self.anchor = nil
    }
}

/// 回看底部栏：播放/暂停、进度、倍速。点击任意句子也会从那里播放。
struct PlaybackBar: View {
    @Bindable var model: AppModel
    @State private var scrubbing: Double?
    @State private var keyMonitor: Any?

    var body: some View {
        let duration = max(model.lesson?.duration ?? 0, 0.1)
        HStack(spacing: 12) {
            Button { model.togglePlayback() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help(model.playing ? "暂停（空格）" : "播放（空格）；← → 前后跳 5 秒")
            .accessibilityIdentifier("playbackToggle")
            Text(Format.clock(scrubbing ?? model.playbackTime)).font(.callout.monospacedDigit()).frame(minWidth: 44, alignment: .trailing)
            Slider(value: Binding(get: { scrubbing ?? model.playbackTime }, set: { scrubbing = $0 }), in: 0...duration) { editing in
                if !editing, let value = scrubbing { model.seek(to: value); scrubbing = nil }
            }
            .controlSize(.small)
            Text(Format.clock(duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Menu {
                Picker("倍速", selection: $model.playbackRate) {
                    ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { Text(rateText($0)).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { Text(rateText(model.playbackRate)).monospacedDigit() }
                .menuStyle(.borderlessButton).fixedSize()
                .help("播放速度")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .frame(maxWidth: 820)
        .padding(.horizontal, 20).padding(.bottom, 14).padding(.top, 6)
        .onAppear { installKeys() }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }
    }

    /// 回看快捷键：空格播放/暂停，← → 前后跳 5 秒。只在主窗口、没有正在输入文字、没有弹窗时生效。
    private func installKeys() {
        guard keyMonitor == nil else { return }
        let model = model
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = event.window, window.identifier?.rawValue == "LectoAIMainWindow", window.attachedSheet == nil,
                  !(window.firstResponder is NSText),
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  [49, 123, 124].contains(event.keyCode) else { return event }
            let code = event.keyCode
            MainActor.assumeIsolated {
                switch code {
                case 49: model.togglePlayback()
                case 123: model.seek(to: model.playbackTime - 5)
                default: model.seek(to: model.playbackTime + 5)
                }
            }
            return nil
        }
    }

    private func rateText(_ rate: Float) -> String {
        rate == 1 ? "1×" : String(format: "%g×", rate)
    }
}
