import AppKit
import LectoAICore
import SwiftUI

/// 打开一堂课时的中间栏：顶部状态横幅、段落字幕、底部记一笔或回放条。
struct TranscriptScreen: View {
    @Bindable var model: AppModel
    @AppStorage("readingMode") private var mode: ReadingMode = .bilingual
    var body: some View {
        VStack(spacing: 0) {
            TranscriptBanners(model: model)
            Group {
                if mode == .summary { SummaryArticle(model: model) } else { TranscriptList(model: model) }
            }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if model.isLive { Composer(model: model) }
                    else if let lesson = model.lesson, !lesson.audio.isEmpty, !model.active { PlaybackBar(model: model) }
                }
        }
        .background(.background)
    }
}

// MARK: 横幅

private struct TranscriptBanners: View {
    @Bindable var model: AppModel
    @AppStorage("readingMode") private var mode: ReadingMode = .bilingual

    var body: some View {
        VStack(spacing: 8) {
            if !model.message.isEmpty {
                Banner(icon: "exclamationmark.triangle.fill", tint: .orange, text: model.message, onClose: { model.message = "" }) { EmptyView() }
            }
            if let lesson = model.lesson, !model.active {
                let just = lesson.id == model.justFinishedID
                if just, lesson.phase == .interrupted {
                    Banner(icon: "exclamationmark.triangle.fill", tint: .orange,
                           text: String(localized: "录音意外中断，已保存到中断前 · \(Format.duration(lesson.duration))")) { EmptyView() }
                }
                if handoffVisible(lesson) {
                    HandoffBanner(model: model, lesson: lesson, justFinished: just && lesson.phase != .interrupted) {
                        if just { model.justFinishedID = nil }
                        model.dismissedFilingPrompts.insert(lesson.id)
                        model.acknowledgeConflicts(lesson)
                    }
                    .transition(.opacity)
                }
            }
            if needsTranslation {
                Banner(icon: "character.book.closed", tint: .blue, text: String(localized: "中文翻译需要先下载系统的英译中语言包。"),
                       detail: String(localized: "原文照常记录；下载后会自动补上这堂课的译文。")) {
                    Button("下载") { model.requestTranslationPreparation() }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, bannerVisible ? 12 : 0)
        .frame(maxWidth: 860)
        .animation(.easeInOut(duration: 0.2), value: bannerVisible)
    }

    private var needsTranslation: Bool {
        guard mode.showsChinese, let lesson = model.lesson, !lesson.lines.isEmpty else { return false }
        return !model.resources.translationInstalled && model.resources.translationSupported
    }

    private var bannerVisible: Bool {
        if !model.message.isEmpty || needsTranslation { return true }
        guard let lesson = model.lesson, !model.active else { return false }
        return lesson.id == model.justFinishedID || handoffVisible(lesson)
    }

    /// 交接横幅何时出现：刚结束的课堂；没交到或有没看过的冲突副本的课堂；以及还没归课、值得再问一次的近期课堂（这次运行里没关掉过）。
    private func handoffVisible(_ lesson: Lesson) -> Bool {
        if lesson.id == model.justFinishedID { return true }
        guard !model.dismissedFilingPrompts.contains(lesson.id) else { return false }
        return model.handoffAttention(lesson) != nil || model.needsFilingPrompt(lesson)
    }
}

// MARK: 字幕列表

private struct TranscriptList: View {
    @Bindable var model: AppModel
    @AppStorage("readingMode") private var mode: ReadingMode = .bilingual
    @AppStorage("captionScale") private var scale = 1.0
    @State private var draftParagraph: UUID?
    private let bottomID = "transcript-bottom"

    var body: some View {
        let lesson = model.lesson
        let items = lesson.map(TranscriptLayout.items(for:)) ?? []
        let loose = lesson.map(TranscriptLayout.looseNotes(for:)) ?? []
        let lastParagraph = items.last.flatMap { item -> DisplayParagraph? in
            if case .paragraph(let value) = item { value } else { nil }
        }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        switch item {
                        case .paragraph(let paragraph):
                            ParagraphView(model: model, paragraph: paragraph, mode: mode, scale: scale,
                                          draftParagraph: $draftParagraph)
                                .id(paragraph.id)
                        case .gap(let gap):
                            if !gap.resolved { GapRow(model: model, gap: gap).id(gap.id) }
                        }
                    }
                    LiveTail(model: model, last: lastParagraph, mode: mode, scale: scale)
                    if items.isEmpty { EmptyTranscript(model: model) }
                    if !loose.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("没有对应字幕的笔记").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(loose) { NoteRow(model: model, note: $0) }
                        }
                        .padding(.leading, 76).padding(.top, 16)
                    }
                    FollowAnchor(model: model, proxy: proxy, bottomID: bottomID)
                        .id(bottomID)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(model.isRecording ? .bottom : .top, for: .initialOffset)
            .onScrollPhaseChange { old, new, context in
                // 只有用户自己滚动才改变跟随状态；停在底部附近则自动恢复跟随。
                // 不用 onScrollGeometryChange：窗口缩放时文字重排会持续触发它，引发约束更新死循环崩溃。
                if new == .interacting { model.followLatest = false }
                if new == .idle, old != .idle {
                    let geometry = context.geometry
                    model.followLatest = geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
                }
            }
            .onChange(of: lesson?.sequence) { _, _ in
                if model.isRecording, model.followLatest { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: model.highlightedLine) { _, line in
                guard let line, let lesson = model.lesson, let target = TranscriptLayout.paragraphID(containing: line, in: lesson) else { return }
                model.followLatest = false
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .center) }
            }
            .onChange(of: model.playingLineID) { _, line in
                guard model.playing, model.followLatest, let line, let lesson = model.lesson,
                      let target = TranscriptLayout.paragraphID(containing: line, in: lesson) else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .center) }
            }
            .overlay(alignment: .bottom) {
                if model.isRecording, !model.followLatest {
                    Button {
                        model.followLatest = true
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                    } label: { Label("回到最新", systemImage: "arrow.down") }
                        .buttonStyle(.glass)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            }
            .environment(\.openURL, OpenURLAction { url in handle(url) })
        }
    }

    /// 句子链接：回看时点击句子从该句播放；AI 引用点击后跳回原文。
    private func handle(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "lectoai", let id = UUID(uuidString: url.lastPathComponent),
              let line = model.lesson?.lines.first(where: { $0.id == id }) else { return .systemAction }
        switch url.host() {
        case "play": model.play(from: line.start); model.followLatest = true
        default: model.highlightedLine = id
        }
        return .handled
    }
}

/// 列表底部的锚点：录音中随临时文字自动跟到最新。单独成视图，避免临时文字刷新整张列表。
private struct FollowAnchor: View {
    @Bindable var model: AppModel
    let proxy: ScrollViewProxy
    let bottomID: String
    var body: some View {
        Color.clear.frame(height: 8)
            .onChange(of: model.partial) { _, _ in
                if model.isRecording, model.followLatest { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
    }
}

private struct EmptyTranscript: View {
    @Bindable var model: AppModel
    var body: some View {
        if model.isRecording, model.partial.isEmpty {
            VStack(spacing: 10) {
                LevelMeter(level: model.level, tint: .accentColor).scaleEffect(1.6)
                Text("正在聆听，老师开口后字幕会出现在这里。").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.top, 80)
        } else if !model.active, model.lesson?.lines.isEmpty == true {
            VStack(spacing: 8) {
                Text("这堂课没有识别出文字").font(.title3.weight(.medium))
                Text(model.lesson?.audio.isEmpty == false ? String(localized: "录音已保存，可以在下方回放。") : String(localized: "没有保存到录音。"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.top, 80)
        }
    }
}

// MARK: 段落

/// 一段：左侧时间，右侧英文段落与紧随的中文段落；笔记挂在段落下方。
private struct ParagraphView: View {
    @Bindable var model: AppModel
    let paragraph: DisplayParagraph
    let mode: ReadingMode
    let scale: Double
    @Binding var draftParagraph: UUID?
    @State private var hovering = false

    var body: some View {
        let review = !model.active
        #if DEBUG
        // 截图自查：--demo-hover 让进行中的段落显示悬停操作。
        let hovering = hovering || (paragraph.isOpen && ProcessInfo.processInfo.arguments.contains("--demo-hover"))
        #endif
        let highlighted = model.highlightedLine.map(paragraph.lineIDs.contains) ?? false
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            gutter(review: review, hovering: hovering)
            VStack(alignment: .leading, spacing: 7 * scale) {
                if mode.showsEnglish {
                    if paragraph.isOpen { LiveEnglishText(model: model, paragraph: paragraph, scale: scale) }
                    else {
                        // 句子链接沿用正文颜色，只在鼠标经过时显示手形，不把整段染成蓝色。
                        Text(englishText(review: review)).font(.system(size: 17 * scale)).lineSpacing(4 * scale)
                            .tint(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if mode.showsChinese {
                    ChineseText(model: model, paragraph: paragraph, mode: mode, scale: scale)
                }
                if !paragraph.notes.isEmpty || draftParagraph == paragraph.id {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(paragraph.notes) { NoteRow(model: model, note: $0) }
                        if draftParagraph == paragraph.id {
                            NewNoteEditor(model: model, paragraph: paragraph) { draftParagraph = nil }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 进行中的段落不开启文字选择：可选文字在内容快速变长时不会及时重新计算高度，会被截成一行。
            .selectableText(!paragraph.isOpen)
        }
        .padding(.vertical, 10)
        .padding(.leading, 6).padding(.trailing, 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(highlighted ? Color.accentColor.opacity(0.12) : hovering ? Color.primary.opacity(0.035) : .clear)
        }
        .contextMenu { menu(review: review) }
        .onHover { self.hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeInOut(duration: 0.3), value: highlighted)
        .task(id: highlighted) {
            // 跳转高亮短暂停留后淡出。
            guard highlighted else { return }
            try? await Task.sleep(for: .seconds(2.5))
            if model.highlightedLine.map(paragraph.lineIDs.contains) == true { model.highlightedLine = nil }
        }
    }

    /// 左侧：段落时间（回看时点击播放）；悬停时在时间下方出现“记笔记 / 问 AI”，不遮挡正文。
    private func gutter(review: Bool, hovering: Bool) -> some View {
        let playable = review && model.lesson?.audio.isEmpty == false
        let speaking = paragraph.isOpen && (model.partial.isEmpty || !model.partialStartsNewParagraph(after: paragraph))
        return VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 4) {
                if speaking { Circle().fill(.red).frame(width: 5, height: 5) }
                if playable {
                    Button { model.play(from: paragraph.start); model.followLatest = true } label: {
                        Text(Format.clock(paragraph.start)).font(.caption.monospacedDigit())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("从这里播放")
                } else {
                    Text(Format.clock(paragraph.start)).font(.caption.monospacedDigit())
                        .foregroundStyle(speaking ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
            }
            if hovering {
                HStack(spacing: 0) {
                    iconButton("square.and.pencil", help: "给这段记笔记") {
                        if model.isRecording { model.followLatest = false }
                        draftParagraph = paragraph.id
                    }
                    iconButton("sparkles", help: "问 AI 这段") { model.askAbout(paragraph) }
                }
                .transition(.opacity)
            }
        }
        .frame(width: 56, alignment: .trailing)
    }

    /// 英文段落：每句一段文字，回看时句子可点击播放；正在播放的句子高亮，有笔记的句子加下划线。
    private func englishText(review: Bool) -> AttributedString {
        let playable = review && model.lesson?.audio.isEmpty == false
        let noted = Set(paragraph.notes.compactMap(\.segmentID))
        var result = AttributedString()
        for (index, sentence) in paragraph.sentences.enumerated() {
            var run = AttributedString(sentence.text)
            if sentence.flagged { run.swiftUI.foregroundColor = .secondary }
            if model.playingLineID == sentence.id { run.swiftUI.backgroundColor = Color.accentColor.opacity(0.2) }
            if noted.contains(sentence.id) { run.swiftUI.underlineStyle = .init(pattern: .solid, color: .orange.opacity(0.6)) }
            if playable { run.link = URL(string: "lectoai://play/\(sentence.id.uuidString)") }
            result += run
            if index < paragraph.sentences.count - 1 { result += AttributedString(" ") }
        }
        return result
    }

    @ViewBuilder private func menu(review: Bool) -> some View {
        Button("给这段记笔记") {
            if model.isRecording { model.followLatest = false }
            draftParagraph = paragraph.id
        }
        Button("问 AI 这段") { model.askAbout(paragraph) }
        Button("复制这段") { copy() }
        if review, model.lesson?.audio.isEmpty == false {
            Divider()
            Button("从这里播放") { model.play(from: paragraph.start); model.followLatest = true }
        }
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.caption).frame(width: 22, height: 20) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(help)
    }

    private func copy() {
        var parts: [String] = []
        if mode.showsEnglish { parts.append(paragraph.english) }
        if mode.showsChinese, let chinese = paragraph.chineseText() { parts.append(chinese) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: "\n"), forType: .string)
        model.toast = Toast(text: String(localized: "已复制这段"))
    }
}

/// 进行中的段落：稳定文字后接浅色的临时识别文字，定稿后原地变深。单独观察 partial，避免整表刷新。
private struct LiveEnglishText: View {
    @Bindable var model: AppModel
    let paragraph: DisplayParagraph
    let scale: Double
    var body: some View {
        var text = AttributedString(paragraph.english)
        if !model.partial.isEmpty, !model.partialStartsNewParagraph(after: paragraph) {
            var tail = AttributedString((paragraph.sentences.isEmpty ? "" : " ") + model.partial.trimmingCharacters(in: .whitespaces))
            tail.swiftUI.foregroundColor = .secondary
            text += tail
        }
        return Text(text).font(.system(size: 17 * scale)).lineSpacing(4 * scale)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 一段中文：草稿（逐句译文）原位升级为整段译文，用淡入过渡，不改变位置。
private struct ChineseText: View {
    @Bindable var model: AppModel
    let paragraph: DisplayParagraph
    let mode: ReadingMode
    let scale: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let primary = mode == .chinese
        let size = (primary ? 17 : 16) * scale
        let style: Color = primary ? .primary : .primary.opacity(0.72)
        let content = composed
        Group {
            if let text = content.text {
                (Text(text).foregroundStyle(style) + tentative(content.pending))
            } else if content.pending {
                tentative(true)
            } else if primary, !paragraph.english.isEmpty {
                // 中文模式下没有译文的历史段落，用浅色原文兜底，避免整段空白。
                Text(paragraph.english).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: size))
        .lineSpacing(5 * scale)
        .fixedSize(horizontal: false, vertical: true)
        .contentTransition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: content.text)
    }

    /// 还在翻译的部分：有临时译文就淡色显示，否则用“…”。
    private func tentative(_ pending: Bool) -> Text {
        guard pending else { return Text("") }
        let speakingHere = paragraph.isOpen && !model.partial.isEmpty && !model.partialStartsNewParagraph(after: paragraph)
        if speakingHere, !model.partialTranslation.isEmpty { return Text(model.partialTranslation).foregroundStyle(.tertiary) }
        return Text(" …").foregroundStyle(.tertiary)
    }

    /// 中文正文与“是否仍有句子在翻译”。
    private var composed: (text: String?, pending: Bool) {
        // 录音中或翻译队列仍在工作：缺的译文还会到来，用“…”表示；否则以原文补位。
        let working = model.isRecording || model.translating
        let speakingHere = paragraph.isOpen && !model.partial.isEmpty && !model.partialStartsNewParagraph(after: paragraph)
        switch paragraph.chinese {
        case .polished(let text): return (text, false)
        case .draft(let pieces):
            let text = pieces.compactMap { $0 }.joined()
            let missing = pieces.contains { $0 == nil }
            if missing, !working {
                // 结束后仍缺译文的句子（资源缺失等）：中文模式以原文补位，避免漏句。
                let filled = zip(paragraph.sentences, pieces).map { sentence, piece in piece ?? (primary ? sentence.text : "") }.joined()
                return (filled, false)
            }
            return (text, missing || speakingHere)
        case .none:
            return (nil, working && model.resources.translationInstalled)
        }
    }

    private var primary: Bool { mode == .chinese }
}

/// 临时文字不属于上一段时（停顿超过 5 秒、刚开始录音），单独显示成新的进行中段落。
private struct LiveTail: View {
    @Bindable var model: AppModel
    let last: DisplayParagraph?
    let mode: ReadingMode
    let scale: Double
    var body: some View {
        if model.isRecording, !model.partial.isEmpty, model.partialStartsNewParagraph(after: last) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                HStack(spacing: 4) {
                    Circle().fill(.red).frame(width: 5, height: 5)
                    Text(Format.clock(model.partialOnset)).font(.caption.monospacedDigit())
                }
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
                VStack(alignment: .leading, spacing: 7 * scale) {
                    if mode.showsEnglish {
                        Text(model.partial.trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 17 * scale)).lineSpacing(4 * scale).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if mode.showsChinese {
                        Text(model.partialTranslation.isEmpty ? "…" : model.partialTranslation)
                            .font(.system(size: (mode == .chinese ? 17 : 16) * scale)).lineSpacing(5 * scale).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 10).padding(.leading, 6).padding(.trailing, 12)
        }
    }
}

// MARK: 笔记

/// 一条笔记或标记：图标、时间、文字；点击补写，悬停可删除。
struct NoteRow: View {
    @Bindable var model: AppModel
    let note: LessonNote
    @State private var draft = ""
    @State private var hovering = false
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        let style = NoteStyle(note.mark)
        let editing = model.editedNote == note.id
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: style.icon).foregroundStyle(style.color).font(.callout)
            Text(Format.clock(note.recordedMediaTime ?? note.mediaTime ?? 0))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if editing {
                TextField(note.mark == nil ? "写下你的想法…" : "补充一句（可选）", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...6).focused($focused)
                    .onAppear { draft = note.text; focused = true }
                    .onChange(of: draft) { _, _ in scheduleSave() }
                    .onSubmit { commit() }
                    .onExitCommand { commit() }
                    .onChange(of: focused) { _, value in if !value { commit() } }
                    .accessibilityIdentifier("noteEditor")
            } else {
                Group {
                    if note.text.isEmpty {
                        Text(style.label).foregroundStyle(style.color == .yellow ? Color.orange : style.color).fontWeight(.medium)
                        + Text(hovering ? "  点击补充" : "").foregroundStyle(.tertiary)
                    } else {
                        Text(note.text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { model.editedNote = note.id }
            }
            Spacer(minLength: 0)
            if hovering, !editing {
                Button { model.deleteNote(note.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("删除（可撤销）")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(style.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
    }

    /// 停止输入 1.5 秒后保存一次，避免每个按键都写入记录。
    private func scheduleSave() {
        saveTask?.cancel()
        let text = draft
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, text != note.text else { return }
            model.updateNote(note.id, text: text)
        }
    }

    private func commit() {
        saveTask?.cancel()
        if model.editedNote == note.id {
            if draft != note.text { model.updateNote(note.id, text: draft) }
            model.editedNote = nil
        }
    }
}

/// 在段落上新建笔记：先出现输入框，写了内容才保存；空着按 Esc 不留下空记录。
private struct NewNoteEditor: View {
    @Bindable var model: AppModel
    let paragraph: DisplayParagraph
    let done: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "pencil.line").foregroundStyle(Color.accentColor).font(.callout)
            Text(Format.clock(paragraph.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            TextField("写下你的想法，回车保存", text: $text, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...6).focused($focused)
                .onSubmit { save() }
                .onExitCommand { done() }
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear { focused = true }
    }

    private func save() {
        let line = model.lesson?.lines.first { $0.id == paragraph.sentences.first?.id }
        model.addNote(text: text, anchor: NoteAnchor(time: model.isLive ? model.elapsed : nil, line: line, quote: nil))
        done()
    }
}

// MARK: 识别缺口

private struct GapRow: View {
    @Bindable var model: AppModel
    let gap: RecognitionGap
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.slash").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.clock(gap.start))–\(Format.clock(gap.end)) 这段没有识别出文字").font(.callout)
                Text(model.active ? String(localized: "录音照常保存，结束后可以补识别。") : String(localized: "录音已保存。") + gap.reason)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if !model.active {
                Button("补识别") { model.repairGaps() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.leading, 76).padding(.vertical, 6)
    }
}
