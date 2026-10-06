import LectoAICore
import SwiftUI
import Translation

/// 标准设置窗口（⌘,）：通用 / 识别与翻译 / AI 助手 / 课程。
struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("settingsTab") private var tab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("通用", systemImage: "gearshape") }.tag(SettingsTab.general.rawValue)
            RecognitionSettings(model: model).tabItem { Label("识别与翻译", systemImage: "waveform") }.tag(SettingsTab.recognition.rawValue)
            AssistantSettings(model: model).tabItem { Label("AI 助手", systemImage: "sparkles") }.tag(SettingsTab.assistant.rawValue)
            // 分页标识仍叫 export，已记住的分页选择不受影响。
            CourseSettings(model: model).tabItem { Label("课程", systemImage: "books.vertical") }.tag(SettingsTab.export.rawValue)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("captionScale") private var captionScale = 1.0
    @AppStorage("floatingScale") private var floatingScale = 1.0
    @AppStorage("floatingTheme") private var floatingTheme = "dark"
    @AppStorage("floatingPinned") private var floatingPinned = true
    @AppStorage("mainPinned") private var mainPinned = false
    @AppStorage("keepScreenOn") private var keepScreenOn = true
    var body: some View {
        Form {
            Picker("外观", selection: $appearance) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            LabeledContent("主窗口字号") {
                ScaleStepper(value: $captionScale)
            }
            Toggle("主窗口保持在最前", isOn: $mainPinned)
            Toggle(isOn: $keepScreenOn) {
                Text("上课时屏幕保持常亮")
                Text("录音期间电脑始终不会自动睡眠；打开后屏幕也不会变暗熄灭，方便一直看字幕。合上屏幕仍会暂停并保存。")
            }
            Section("小窗") {
                LabeledContent("字号") { ScaleStepper(value: $floatingScale) }
                Picker("外观", selection: $floatingTheme) {
                    Text("深色").tag("dark")
                    Text("浅色").tag("light")
                }
                .pickerStyle(.segmented)
                Toggle("置顶（浮在所有窗口和全屏 App 之上）", isOn: $floatingPinned)
            }
            Text("小窗的显示内容（原文/双语/中文/纪要）在小窗右上角 ⋯ 里切换。动效跟随系统“减弱动态效果”设置。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct ScaleStepper: View {
    @Binding var value: Double
    var body: some View {
        HStack(spacing: 8) {
            Button { value = CaptionScale.smaller(value) } label: { Image(systemName: "textformat.size.smaller") }
                .disabled(value <= CaptionScale.steps.first! + 0.01)
            Text("\(Int((value * 100).rounded()))%").monospacedDigit().frame(width: 48)
            Button { value = CaptionScale.larger(value) } label: { Image(systemName: "textformat.size.larger") }
                .disabled(value >= CaptionScale.steps.last! - 0.01)
        }
    }
}

private struct RecognitionSettings: View {
    @Bindable var model: AppModel
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var preparing = false
    @State private var translationNote = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("英语识别") {
                    HStack(spacing: 8) {
                        Text(model.resources.speechInstalled ? String(localized: "已就绪") : model.resources.speech).foregroundStyle(.secondary)
                        if model.resources.downloading {
                            ProgressView(value: model.resources.downloadProgress?.fractionCompleted ?? 0).frame(width: 80)
                            Button("取消") { model.resources.cancelDownload() }
                        } else if model.resources.speechCanDownload, !model.resources.speechInstalled {
                            Button("下载") { model.resources.downloadSpeech() }
                        }
                    }
                }
                LabeledContent("英译中") {
                    HStack(spacing: 8) {
                        Text(!translationNote.isEmpty ? translationNote : model.resources.translationInstalled ? String(localized: "已就绪") : model.resources.translation)
                            .foregroundStyle(.secondary)
                        if preparing { ProgressView().controlSize(.small) }
                        else if model.resources.translationSupported, !model.resources.translationInstalled {
                            Button("下载") {
                                preparing = true
                                if translationConfig == nil { translationConfig = .init(source: .init(identifier: "en"), target: .init(identifier: "zh-Hans")) }
                                else { translationConfig?.invalidate() }
                            }
                        }
                    }
                }
            } footer: {
                Text("识别和翻译都在这台 Mac 上完成，不上传录音。")
            }
            // 离线语音模型只在系统识别不可用、或已经下载过时出现（主设计 §6.6：用户无需选择引擎）。
            if showsOfflineModel {
                Section {
                    LabeledContent("离线语音模型") {
                        HStack(spacing: 8) {
                            Text(model.whisper.status).foregroundStyle(.secondary).lineLimit(2)
                            if model.whisper.downloading {
                                ProgressView(value: model.whisper.progress).frame(width: 80)
                                Button("取消") { model.whisper.cancel() }
                            } else if model.whisper.ready {
                                Button("移除") { model.whisper.remove() }.disabled(model.active)
                            } else {
                                Button("下载") { model.whisper.download() }.disabled(model.active)
                            }
                        }
                    }
                } footer: {
                    Text("系统语音识别不可用时，LectoAI 会自动改用离线模型（约 630 MB），无需手动切换。")
                }
            }
            Section {
                Button("导出诊断信息…") { model.exportDiagnostics() }
            } footer: {
                Text("诊断信息不包含课堂内容、API 地址、密钥或文件夹路径。")
            }
        }
        .formStyle(.grouped)
        .task { await model.resources.refresh(); await model.whisper.refresh() }
        .translationTask(translationConfig, action: prepare)
    }

    private var showsOfflineModel: Bool {
        model.whisper.ready || model.whisper.downloading || (model.resources.checkedOnce && !model.resources.speechInstalled && !model.resources.speechCanDownload)
    }

    private nonisolated func prepare(_ session: TranslationSession) async {
        let failure: String?
        do { try await session.prepareTranslation(); failure = nil } catch { failure = error.localizedDescription }
        await finish(failure)
    }

    private func finish(_ failure: String?) async {
        preparing = false
        translationNote = failure.map { String(localized: "准备失败：\($0)") } ?? ""
        await model.resources.refresh()
        if model.resources.translationInstalled { model.translatePending() }
    }
}
