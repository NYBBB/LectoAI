import LectoAICore
import SwiftUI

/// 右侧 AI 助手：此刻（话题/阶段/提示）、重点、问答；输入固定在底部。
struct AssistantPanel: View {
    @Bindable var model: AppModel
    @AppStorage("apiEndpoint") private var endpoint = ""
    @AppStorage("apiModel") private var modelName = ""
    @AppStorage("autoDigest") private var autoDigest = true

    private var configured: Bool { (try? ModelProfile(endpoint: endpoint, model: modelName).url()) != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !configured {
                ConnectCard(model: model)
            } else if let lesson = model.lesson {
                AssistantContent(model: model, lesson: lesson)
                AssistantInput(model: model)
            } else if let recent = model.history.first(where: { $0.digest?.isEmpty == false }) {
                RecentDigest(model: model, lesson: recent)
            } else {
                ContentUnavailableView("开始或打开一堂课", systemImage: "sparkles",
                                       description: Text("上课时这里会自动整理课堂纪要，也可以随时提问。"))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 40)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("AI 助手", systemImage: "sparkles").font(.headline).labelStyle(.titleAndIcon)
            Spacer()
            if configured, model.lesson != nil {
                if model.digestBusy {
                    ProgressView().controlSize(.small).help("正在整理纪要")
                } else {
                    Button { model.refreshDigest() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .disabled(model.lesson?.lines.isEmpty != false)
                        .help("立即整理纪要")
                }
            }
            Menu {
                Toggle("课中自动整理纪要", isOn: $autoDigest).disabled(!configured)
                Divider()
                Button("整理我的笔记") { model.organizeNotes() }
                    .disabled(!configured || model.aiBusy || model.lesson?.notes.contains { !$0.deleted } != true)
                Button("查看笔记整理") { model.showStudyDraft = true }
                    .disabled(model.lesson?.studyDrafts?.isEmpty != false)
                Divider()
                Button("AI 调用记录…") { model.showAICalls = true }
                    .disabled(model.lesson?.aiCalls?.isEmpty != false)
                Button("AI 设置…") { model.settingsRequest = .assistant }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("更多")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// 未连接时的就地说明：用途、隐私边界、一个连接按钮。
private struct ConnectCard: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(.tint)
            Text("连接 AI 服务").font(.title3.weight(.semibold))
            Text("使用你自己的 API（兼容 OpenAI 的接口）。连接后可以：")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Label("随时问这段在讲什么", systemImage: "questionmark.bubble")
                Label("自动整理当前话题与重点", systemImage: "list.bullet.rectangle")
                Label("逐条解释你标记的“没听懂”", systemImage: "questionmark.circle")
            }
            .font(.callout)
            Text("只发送有限的课堂文字，不上传录音。字幕与笔记不需要 AI 也能完整使用。")
                .font(.caption).foregroundStyle(.secondary)
            Button("连接…") { model.settingsRequest = .assistant }
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AssistantContent: View {
    @Bindable var model: AppModel
    let lesson: Lesson
    @AppStorage("autoDigest") private var autoDigest = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var appear: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity)
    }

    /// 纪要小节与提问按课堂时间排成一条时间线；课后提问（没有课堂时间）放在最后。
    private enum Entry: Identifiable {
        case section(DigestSection, latest: Bool)
        case answer(LessonAnswer)
        var id: UUID { switch self { case .section(let value, _): value.id; case .answer(let value): value.id } }
        var time: Double { switch self { case .section(let value, _): value.start; case .answer(let value): value.mediaTime ?? .infinity } }
    }

    private var entries: [Entry] {
        let sections = lesson.digest ?? []
        let items = sections.map { Entry.section($0, latest: $0.id == sections.last?.id) } + lesson.answers.map(Entry.answer)
        return items.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FocusCard(lesson: lesson, live: model.isLive)
                    if !model.digestStatus.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Label(model.digestStatus, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                            Spacer(minLength: 4)
                            Button("查看记录") { model.showAICalls = true }.buttonStyle(.link).font(.caption)
                        }
                    }
                    if lesson.digest?.isEmpty != false, lesson.structuredInsight != nil {
                        LegacyInsight(model: model, lesson: lesson)
                    }
                    if entries.isEmpty, model.streamingQuestion == nil, lesson.structuredInsight == nil {
                        if !model.isLive, !lesson.lines.isEmpty {
                            DigestPrompt(model: model)
                        } else {
                            Text(emptyHint).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(entries) { entry in
                        switch entry {
                        case .section(let section, let latest):
                            SectionCard(model: model, section: section, lines: lesson.lines, updating: latest && model.isLive)
                                .transition(appear)
                        case .answer(let answer):
                            AnswerView(question: answer.question, answer: answer.answer, lines: lesson.lines, time: answer.mediaTime)
                                .transition(appear)
                        }
                    }
                    if let question = model.streamingQuestion {
                        AnswerView(question: question, answer: model.answerDraft, lines: lesson.lines, time: model.isLive ? model.elapsed : nil, streaming: true)
                    }
                    Color.clear.frame(height: 1).id("assistant-bottom")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 新小节、新问答从下方淡入；小节内容更新时平滑展开，不硬切。
                .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.12), value: entries.map(\.id))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: lesson.digest)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: lesson.focus)
            }
            .onChange(of: (lesson.digest?.count ?? 0) + lesson.answers.count) { _, _ in
                withAnimation { proxy.scrollTo("assistant-bottom", anchor: .bottom) }
            }
            .onChange(of: model.answerDraft) { _, _ in proxy.scrollTo("assistant-bottom", anchor: .bottom) }
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "lectoai", let id = UUID(uuidString: url.lastPathComponent) else { return .systemAction }
                model.highlightedLine = id
                return .handled
            })
        }
    }

    private var emptyHint: String {
        if lesson.lines.isEmpty { return String(localized: "有课堂原文后，这里会按话题整理课堂纪要：每节一句概述和几条带出处的要点。") }
        if model.isLive && autoDigest { return String(localized: "上课约 2 分钟、有足够内容后会出现第一节纪要；也可以点右上角 ↻ 立即整理。") }
        return String(localized: "点右上角 ↻ 立即整理纪要。")
    }
}

/// 回看一堂还没整理过的课：直接给出整理按钮，而不是让人去找右上角。
private struct DigestPrompt: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("这堂课还没有纪要").font(.headline)
            Text("按话题整理成几节，每节一句概述和几条带出处的要点，点时间可跳回原文。")
                .font(.callout).foregroundStyle(.secondary)
            if model.digestBusy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在整理…").font(.callout).foregroundStyle(.secondary) }
            } else {
                Button { model.refreshDigest() } label: { Label("整理这堂课的纪要", systemImage: "list.bullet.rectangle") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("makeDigest")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 开始页：没有打开的课堂时，显示最近一堂有纪要的课（概述与提醒），上课前可以快速回顾。
private struct RecentDigest: View {
    @Bindable var model: AppModel
    let lesson: Lesson
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("最近的纪要").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(lesson.title).font(.title3.weight(.semibold))
                    Text(lesson.createdAt.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute()))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(lesson.digest ?? []) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(section.title).font(.headline)
                            Spacer(minLength: 4)
                            Text(Format.clock(section.start)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                        if !section.summary.isEmpty {
                            Text(section.summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        ForEach(Array(section.points.filter { $0.kind == "notice" }.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                KindTag(kind: point.kind)
                                Text(point.text).font(.callout).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Button("打开这堂课") { model.open(lesson) }
                    .buttonStyle(.link)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 此刻：当前话题、阶段与一句提示。回看时显示为“最后在讲”。
private struct FocusCard: View {
    let lesson: Lesson
    let live: Bool
    var body: some View {
        if let focus = lesson.focus {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(live ? "此刻" : "最后在讲").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(LectureDigest.phases[focus.phase] ?? focus.phase)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                    Spacer()
                    Text("\(Format.clock(focus.at)) 更新").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Text(focus.topic).font(.title3.weight(.semibold)).textSelection(.enabled)
                    .contentTransition(.opacity)
                if !focus.hint.isEmpty { Text(focus.hint).font(.callout).foregroundStyle(.tint).contentTransition(.opacity) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// 纪要中的一节：标题、时间范围（点击跳回原文）、一句概述、带类型与出处的要点。
private struct SectionCard: View {
    @Bindable var model: AppModel
    let section: DigestSection
    let lines: [TranscriptLine]
    let updating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(section.title).font(.headline).textSelection(.enabled)
                if updating {
                    Text("更新中").font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
                }
                Spacer(minLength: 4)
                Button("\(Format.clock(section.start))–\(Format.clock(section.end))") {
                    if let first = section.points.first?.sources.first ?? lines.first(where: { $0.start >= section.start - 0.01 })?.id {
                        model.highlightedLine = first
                    }
                }
                .buttonStyle(.link).font(.caption.monospacedDigit())
                .help("跳到这一节的原文")
            }
            if !section.summary.isEmpty {
                Text(section.summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(section.points.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        KindTag(kind: point.kind)
                            .contentTransition(.opacity)
                        Text(point.text).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let id = point.sources.first, let line = lines.first(where: { $0.id == id }) {
                            Button(Format.clock(line.start)) { model.highlightedLine = id }
                                .buttonStyle(.link).font(.caption2.monospacedDigit())
                                .help("跳到原文")
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 要点类型标签：概念 / 重点 / 例子 / 提醒。
struct KindTag: View {
    let kind: String
    var body: some View {
        Text(LectureDigest.kinds[kind] ?? "重点")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
    private var color: Color {
        switch kind {
        case "concept": .blue
        case "example": .green
        case "notice": .red
        default: .orange
        }
    }
}

/// 0.3.0 之前的“话题与重点”记录：只读显示，不再生成。
private struct LegacyInsight: View {
    @Bindable var model: AppModel
    let lesson: Lesson
    var body: some View {
        if let state = lesson.structuredInsight {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.topic).font(.headline)
                ForEach(Array(state.keyPoints.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        KindTag(kind: "key")
                        Text(point.text).font(.callout).textSelection(.enabled)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// 一问一答。回答里的 [片段ID] 渲染为可点击的课堂时间。
private struct AnswerView: View {
    let question: String
    let answer: String
    let lines: [TranscriptLine]
    var time: Double? = nil
    var streaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let time {
                Text("\(Format.clock(time)) 你问").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text(question)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
            MarkdownBlocks(source: CitationText.render(answer, lines: lines) { id, time in "[\(time)](lectoai://line/\(id.uuidString))" })
            if streaming { ProgressView().controlSize(.small) }
        }
    }

}

/// 输入区：快捷问题、可移除的引用、输入框与发送/停止。
private struct AssistantInput: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        let hasText = model.lesson?.lines.isEmpty == false
        VStack(alignment: .leading, spacing: 8) {
            // 放在横向滚动里：按钮再多也不会撑宽检查器，避免窗口尺寸反复重算。
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    quick("解释刚才这段", .explainLatest, help: "解释最近一段在讲什么")
                    quick("最近 5 分钟", .recap, help: "概括最近 5 分钟讲了什么")
                    quick("没听懂的地方", .confused, help: "逐条解释你标记“没听懂”的地方")
                }
            }
            .disabled(model.aiBusy || !hasText)
            VStack(alignment: .leading, spacing: 6) {
                if let reference = referenceText {
                    HStack(spacing: 6) {
                        Image(systemName: "text.quote").foregroundStyle(.secondary)
                        Text(reference).lineLimit(2).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button { model.questionReferences = [] } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.tertiary).help("不带这段引用")
                    }
                    .font(.caption)
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(model.questionReferences.isEmpty ? "问 AI…" : "关于这段，你想问什么？", text: $model.question, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .focused($focused)
                        .onSubmit { model.ask() }
                        .accessibilityIdentifier("askField")
                    if model.aiBusy {
                        Button { model.cancelAI() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                            .buttonStyle(.borderless).help("停止生成")
                    } else {
                        Button { model.ask() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                            .buttonStyle(.borderless)
                            .disabled(model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasText)
                            .help("发送（回车）")
                    }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? Color.accentColor.opacity(0.5) : .clear))
        }
        .padding(12)
        .onChange(of: model.questionFocusRequest) { _, _ in focused = true }
    }

    private func quick(_ title: LocalizedStringKey, _ kind: AppModel.QuickQuestion, help: LocalizedStringKey) -> some View {
        Button(title) { model.ask(kind) }
            .buttonStyle(.bordered).controlSize(.small)
            .help(help)
    }

    private var referenceText: String? {
        guard let lesson = model.lesson, let first = model.questionReferences.first,
              let line = lesson.lines.first(where: { $0.id == first }) else { return nil }
        let text = model.questionReferences.compactMap { id in lesson.lines.first { $0.id == id }?.original }.joined(separator: " ")
        return "\(Format.clock(line.start)) · \(text)"
    }
}

/// “整理我的笔记”的结果：AI 生成的候选，原笔记不变。
struct StudyDraftSheet: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("笔记整理").font(.title2.weight(.semibold))
                    Text("AI 根据你的笔记和课堂原文生成，原来的笔记保持不变；导出时一并写入“笔记整理候选.md”。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { model.showStudyDraft = false }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                if let draft = model.lesson?.studyDrafts?.last, let lesson = model.lesson {
                    AnswerText(text: draft.text, lines: lesson.lines)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("还没有整理结果。").foregroundStyle(.secondary)
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "lectoai", let id = UUID(uuidString: url.lastPathComponent) else { return .systemAction }
                model.showStudyDraft = false
                model.highlightedLine = id
                return .handled
            })
        }
        .padding(24)
        .frame(width: 680, height: 580)
    }
}

private struct AnswerText: View {
    let text: String
    let lines: [TranscriptLine]
    var body: some View {
        MarkdownBlocks(source: CitationText.render(text, lines: lines) { id, time in "[\(time)](lectoai://line/\(id.uuidString))" }, font: .body)
    }
}

/// AI 调用记录（O1）：每次纪要、问答、整理的耗时、字数与失败原因；失败时可展开看模型原始输出。
struct AICallsSheet: View {
    @Bindable var model: AppModel

    private static let kinds = ["digest": "纪要", "answer": "问答", "notes": "笔记整理", "translate": "翻译", "summary": "总结文章"]

    var body: some View {
        let calls = Array((model.lesson?.aiCalls ?? []).reversed())
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI 调用记录").font(.title2.weight(.semibold))
                    Text(summary(calls)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { model.showAICalls = false }.keyboardShortcut(.defaultAction)
            }
            List(calls) { call in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: call.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(call.ok ? .green : .red)
                        Text(Self.kinds[call.kind] ?? call.kind).font(.headline)
                        Text(call.mediaTime.map { "课堂 \(Format.clock($0))" } ?? call.at.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Text(call.model).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Text(metrics(call)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let error = call.error {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let output = call.output, !output.isEmpty {
                        DisclosureGroup("模型原始输出") {
                            Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay { if calls.isEmpty { ContentUnavailableView("还没有 AI 调用", systemImage: "sparkles") } }
        }
        .padding(24)
        .frame(width: 640, height: 560)
    }

    private func metrics(_ call: AICall) -> String {
        let first = call.firstTokenSeconds.map { String(format: "首字 %.1f 秒 · ", $0) } ?? ""
        let thought = (call.reasoningCharacters ?? 0) > 0 ? " · 思考 \(call.reasoningCharacters!) 字" : ""
        return first + String(format: "共 %.1f 秒 · 发送 %d 字 · 返回 %d 字", call.totalSeconds, call.inputCharacters, call.outputCharacters) + thought
    }

    private func summary(_ calls: [AICall]) -> String {
        guard !calls.isEmpty else { return "这堂课还没有调用 AI。" }
        let failed = calls.filter { !$0.ok }.count
        let average = calls.map(\.totalSeconds).reduce(0, +) / Double(calls.count)
        let firsts = calls.compactMap(\.firstTokenSeconds)
        let first = firsts.isEmpty ? "" : String(format: " · 平均首字 %.1f 秒", firsts.reduce(0, +) / Double(firsts.count))
        return "共 \(calls.count) 次 · 失败 \(failed) 次" + first + String(format: " · 平均耗时 %.1f 秒", average)
    }
}
