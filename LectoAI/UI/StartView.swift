import AppKit
import LectoAICore
import SwiftUI

/// 没有打开课堂时的开始页：一个主按钮 + 音源 + 就地准备清单，替代首次启动向导。
struct StartView: View {
    @Bindable var model: AppModel
    @AppStorage("apiEndpoint") private var endpoint = ""
    @AppStorage("apiModel") private var modelName = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 56)).foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("新的一堂课").font(.title.weight(.semibold))
                }
                .padding(.top, 44)

                VStack(spacing: 14) {
                    startButton
                    Picker("音源", selection: $model.sourceSystem) {
                        Label("麦克风（现场上课）", systemImage: "mic").tag(false)
                        Label("电脑声音（网课）", systemImage: "speaker.wave.2").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 330)
                    .disabled(model.active || model.preparingStart)
                }

                if let interrupted = model.history.first, interrupted.phase == .interrupted {
                    Banner(icon: "exclamationmark.triangle.fill", tint: .orange,
                           text: String(localized: "上次的课堂意外中断，录音已保存到中断前。")) {
                        Button("打开") { model.open(interrupted) }
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text("准备情况").font(.headline).padding(.bottom, 10)
                    VStack(spacing: 0) {
                        speechRow
                        Divider().padding(.leading, 40)
                        translationRow
                        Divider().padding(.leading, 40)
                        aiRow
                        Divider().padding(.leading, 40)
                        courseRow
                    }
                    .panelBackground(cornerRadius: 12)
                }

                Button("导入录音文件…") { model.chooseFile() }
                    .buttonStyle(.link)
                    .disabled(model.active)
                    .help("把已有的课堂录音转成字幕与译文（按实际时长处理）")
                    .padding(.bottom, 30)
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
        }
        .task {
            await model.resources.refresh()
            await model.whisper.refresh()
        }
    }

    @ViewBuilder private var startButton: some View {
        if needsOfflineModel {
            Button { Task { await model.downloadOfflineModelAndStart() } } label: {
                Label("下载离线语音模型并开始", systemImage: "arrow.down.circle.fill").frame(minWidth: 230)
            }
            .buttonStyle(.borderedProminent).controlSize(.extraLarge)
            .disabled(model.preparingStart || model.whisper.downloading)
        } else {
            Button { Task { await model.startListening() } } label: {
                Label(model.preparingStart ? String(localized: "正在准备英语识别…") : String(localized: "开始听课"),
                      systemImage: model.sourceSystem ? "speaker.wave.2.fill" : "mic.fill")
                    .frame(minWidth: 230)
            }
            .buttonStyle(.borderedProminent).controlSize(.extraLarge).tint(.red)
            .keyboardShortcut(.defaultAction)
            .disabled(model.active || model.preparingStart || model.updateSession)
            .accessibilityIdentifier("startListening")
        }
    }

    /// Apple 识别在本机不可用且离线模型未下载：主按钮改为下载离线模型（主设计 §6.6）。
    private var needsOfflineModel: Bool {
        let resources = model.resources
        return resources.checkedOnce && !resources.speechInstalled && !resources.speechCanDownload && !model.whisper.ready
    }

    // MARK: 准备清单

    private var speechRow: some View {
        let resources = model.resources
        return ReadinessRow(icon: "waveform", title: "英语识别") {
            if resources.speechInstalled {
                ReadyLabel(text: String(localized: "已就绪"))
            } else if resources.downloading {
                ProgressLabel(text: String(localized: "正在下载"), value: resources.downloadProgress?.fractionCompleted)
            } else if resources.speechCanDownload {
                ActionLabel(text: String(localized: "需要下载系统语音资源"), action: String(localized: "下载")) { model.resources.downloadSpeech() }
            } else if model.whisper.ready {
                ReadyLabel(text: String(localized: "使用离线语音模型"))
            } else if model.whisper.downloading {
                ProgressLabel(text: String(localized: "正在下载离线模型"), value: model.whisper.progress)
            } else if resources.checkedOnce {
                ActionLabel(text: String(localized: "系统识别不可用，需要离线模型（约 630 MB）"), action: String(localized: "下载")) { model.whisper.download() }
            } else {
                ProgressLabel(text: String(localized: "正在检查"), value: nil)
            }
        }
    }

    private var translationRow: some View {
        let resources = model.resources
        return ReadinessRow(icon: "character.book.closed", title: "中文翻译") {
            if resources.translationInstalled {
                ReadyLabel(text: String(localized: "已就绪"))
            } else if resources.translationSupported {
                ActionLabel(text: String(localized: "需要下载英译中语言包"), action: String(localized: "下载")) { model.requestTranslationPreparation() }
            } else if resources.checkedOnce {
                Text("这台 Mac 不支持英译中").font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressLabel(text: String(localized: "正在检查"), value: nil)
            }
        }
    }

    private var aiRow: some View {
        ReadinessRow(icon: "sparkles", title: "AI 助手", optional: true) {
            if (try? ModelProfile(endpoint: endpoint, model: modelName).url()) != nil {
                ReadyLabel(text: modelName)
            } else {
                ActionLabel(text: String(localized: "用于提问和整理重点"), action: String(localized: "连接")) { model.settingsRequest = .assistant }
            }
        }
    }

    /// 课程不是开始的前提：没有课程时什么都不用做，下课时在横幅上选一次文件夹就建好了。
    private var courseRow: some View {
        ReadinessRow(icon: "books.vertical", title: "课程", optional: true) {
            if model.courses.active.isEmpty {
                ActionLabel(text: String(localized: "下课时再放进课程文件夹"), action: String(localized: "现在选")) { model.beginNewCourse(for: nil) }
            } else {
                CoursePicker(model: model)
            }
        }
    }
}

private struct ReadinessRow<Status: View>: View {
    let icon: String
    let title: LocalizedStringKey
    var optional = false
    @ViewBuilder var status: Status
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(title)
                if optional { Text("可选").font(.caption).foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 12)
            status
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
    }
}

private struct ReadyLabel: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout).foregroundStyle(.secondary)
            .labelStyle(TrailingIconLabelStyle(tint: .green))
            .lineLimit(1)
    }
}

private struct ProgressLabel: View {
    let text: String
    let value: Double?
    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(.callout).foregroundStyle(.secondary)
            if let value { ProgressView(value: value).frame(width: 70) } else { ProgressView().controlSize(.small) }
        }
    }
}

private struct ActionLabel: View {
    let text: String
    let action: String
    let perform: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
            Button(action, action: perform).controlSize(.small)
        }
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon.foregroundStyle(tint)
        }
    }
}
