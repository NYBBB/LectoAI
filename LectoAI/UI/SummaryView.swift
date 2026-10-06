import LectoAICore
import SwiftUI

/// 主窗口“总结”页（U9）：顶部“此刻”，下面是按课堂进度续写的连续笔记文章。
/// 约 1.5–2 分钟才多一段，新段落淡入；不显示滚动的同传字幕，适合上课常开。
struct SummaryArticle: View {
    @Bindable var model: AppModel
    @AppStorage("captionScale") private var scale = 1.0
    @AppStorage("readingMode") private var mode: ReadingMode = .bilingual
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let lesson = model.lesson {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        SummaryNow(model: model, lesson: lesson)
                        content(lesson)
                        Color.clear.frame(height: 1).id("summary-bottom")
                    }
                    .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 24)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: lesson.article)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: lesson.focus)
                }
                .defaultScrollAnchor(model.isLive ? .bottom : .top, for: .initialOffset)
                .onChange(of: lesson.article?.count ?? 0) { _, _ in
                    guard model.isLive else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) { proxy.scrollTo("summary-bottom", anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder private func content(_ lesson: Lesson) -> some View {
        let article = lesson.article ?? []
        if !model.aiConfigured {
            hint("连接 AI 后，这里会随课堂进度续写一篇中文笔记：每 1–2 分钟一段，只写老师讲到的内容。") {
                Button("连接 AI…") { model.settingsRequest = .assistant }.buttonStyle(.borderedProminent)
            }
        } else if article.isEmpty {
            if model.isLive {
                hint(model.articleBusy ? "正在写第一段…" : "上课约 1–2 分钟后，这里会出现第一段总结。") {
                    if model.articleBusy { ProgressView().controlSize(.small) }
                }
            } else if !lesson.lines.isEmpty {
                hint("这堂课还没有总结。按课堂进度把整堂课写成一篇连续的中文笔记。") {
                    if model.articleBusy {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在写…").foregroundStyle(.secondary) }
                    } else {
                        Button { model.refreshArticle(wholeLesson: true) } label: { Label("生成这堂课的总结", systemImage: "text.alignleft") }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("makeArticle")
                    }
                }
            }
        }
        ForEach(article) { paragraph in
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Button(Format.clock(paragraph.start)) { jump(to: paragraph, in: lesson) }
                    .buttonStyle(.plain)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
                    .help("在双语字幕中查看这一段的原文")
                Text(paragraph.text)
                    .font(.system(size: 17 * scale))
                    .lineSpacing(7 * scale)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
        }
        if !article.isEmpty {
            if model.articleBusy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在续写…").font(.callout).foregroundStyle(.secondary) }
                    .padding(.leading, 62)
            } else if !model.isLive, LectureArticle.isDue(lesson, final: true) {
                Button("补写剩余部分") { model.refreshArticle(wholeLesson: true) }
                    .buttonStyle(.link).padding(.leading, 62)
            }
        }
        if !model.articleStatus.isEmpty {
            HStack(spacing: 6) {
                Label(model.articleStatus, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                Button("查看记录") { model.showAICalls = true }.buttonStyle(.link).font(.caption)
            }
            .padding(.leading, 62)
        }
    }

    private func hint<Actions: View>(_ text: LocalizedStringKey, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).font(.body).foregroundStyle(.secondary)
            actions()
        }
        .padding(.leading, 62)
    }

    /// 点时间：切到双语字幕并高亮这一段的第一句。
    private func jump(to paragraph: ArticleParagraph, in lesson: Lesson) {
        guard let line = lesson.lines.first(where: { $0.start >= paragraph.start - 0.01 }) else { return }
        mode = .bilingual
        Task { try? await Task.sleep(for: .milliseconds(200)); model.highlightedLine = line.id }
    }
}

/// 总结页顶部：此刻的话题、阶段与一句提示；课后显示为“最后在讲”。
private struct SummaryNow: View {
    @Bindable var model: AppModel
    let lesson: Lesson

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if model.isRecording {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("此刻 · \(Format.clock(model.elapsed))").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                } else {
                    Text(model.isLive ? "已暂停" : "最后在讲").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                if let focus = lesson.focus {
                    Text(LectureDigest.phases[focus.phase] ?? focus.phase)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
            }
            if let focus = lesson.focus {
                Text(focus.topic).font(.title2.weight(.semibold)).contentTransition(.opacity)
                if !focus.hint.isEmpty {
                    Text(focus.hint).font(.callout).foregroundStyle(.tint).contentTransition(.opacity)
                }
            } else {
                Text(lesson.title).font(.title2.weight(.semibold))
                Text(model.isLive ? "正在听课，话题识别出来后会显示在这里。" : "").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
