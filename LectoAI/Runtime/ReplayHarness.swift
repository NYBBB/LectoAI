#if DEBUG
import Foundation
import LectoAICore

/// 仅 Debug：把一堂真实课堂的原文按课堂时间回放进隔离资料库，模拟课中每 2 分钟整理一次纪要，
/// 用真实模型验证纪要/标题/调用记录（2026-09-29 课堂纪要全部失败后加入）。
/// 用法：--test-workspace --replay-lesson <events.jsonl> [--real-ai] [--replay-limit 秒]
/// 只读源文件；结果写到临时目录的 replay-report.json，并在控制台打印路径。
@MainActor
enum ReplayHarness {
    private struct Row: Decodable { let change: LessonChange }

    static func run(model: AppModel, repository: LessonRepository, source: URL) async {
        let arguments = ProcessInfo.processInfo.arguments
        let limit = arguments.firstIndex(of: "--replay-limit").flatMap { Double(arguments[$0 + 1]) } ?? .infinity
        do {
            var changes: [LessonChange] = []
            for line in try String(contentsOf: source, encoding: .utf8).split(separator: "\n") {
                guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)) else { continue }
                switch row.change {
                // 源课堂的整段译文按旧段落规则生成，回放时由新流程重新产生，所以不导入。
                case .line, .translation: changes.append(row.change)
                default: break
                }
            }
            let lines = changes.compactMap { if case .line(let value) = $0 { value } else { nil } }.filter { $0.start < limit }
            let end = min(limit, lines.map(\.end).max() ?? 0)
            var lesson = try await repository.create(title: AppModel.defaultTitle(for: Date()), source: "回放")
            model.open(lesson)
            lesson = try await repository.append(.phase(.recording, 0), to: lesson.id)
            model.lesson = lesson
            model.beginReplay(lesson)
            NSLog("replay start: %d lines, %.0f s", lines.count, end)
            var applied = Set<Int>()
            var tick = 30.0
            var lastDigest = 0.0
            var askedLive = false
            while true {
                let now = min(tick, end)
                // 把课堂时间 now 之前的原文、译文、整段译文写入。
                for (index, change) in changes.enumerated() where !applied.contains(index) {
                    let time: Double?
                    switch change {
                    case .line(let value): time = value.start
                    case .translation(let id, _, _): time = lines.first { $0.id == id }?.start
                    default: time = nil
                    }
                    guard let time, time < now else { continue }
                    lesson = try await repository.append(change, to: lesson.id)
                    applied.insert(index)
                }
                model.lesson = lesson
                model.elapsed = now
                // 与课中一致：每段结束即 AI 翻译；约 2 分钟整理一次纪要。
                model.translateWithAI()
                while model.aiTranslating { try? await Task.sleep(for: .milliseconds(200)) }
                model.refreshArticle(final: now >= end)
                if now - lastDigest >= 120 || now >= end { model.refreshDigest(manual: false); lastDigest = now }
                while model.digestBusy || model.aiTranslating || model.articleBusy { try? await Task.sleep(for: .milliseconds(200)) }
                lesson = model.lesson ?? lesson
                let calls = lesson.aiCalls ?? []
                NSLog("replay tick %.0f s: calls=%d failed=%d sections=%d status=%@", now, calls.count, calls.filter { !$0.ok }.count,
                      lesson.digest?.count ?? 0, model.digestStatus)
                // 课中提问一次（课中规则：最近 5 分钟 + 总结记忆，短答）。
                if !askedLive, now >= min(600, end) {
                    askedLive = true
                    model.question = "现在在讲什么？"
                    model.ask()
                    while model.aiBusy { try? await Task.sleep(for: .milliseconds(200)) }
                }
                if now >= end { break }
                tick += 30
            }
            lesson = try await repository.append(.phase(.completed, end), to: lesson.id)
            model.lesson = lesson
            // 课后提问一次（复习规则，可以详细）。
            model.question = "这堂课讲的切分阈值是怎么选的？"
            model.ask()
            while model.aiBusy { try? await Task.sleep(for: .milliseconds(200)) }
            lesson = model.lesson ?? lesson
            try report(lesson)
        } catch { NSLog("replay failed: %@", error.localizedDescription) }
        NSLog("replay done")
    }

    /// 用同一份纪要请求试几种“关闭思考”的参数，记录首字时间、思考字数、回答字数与总耗时（--probe-ai）。
    static func probe(model: AppModel, source: URL, seconds: Double) async {
        do {
            var lesson = Lesson(title: "探测", source: "回放")
            for line in try String(contentsOf: source, encoding: .utf8).split(separator: "\n") {
                guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)) else { continue }
                if case .line(let value) = row.change, value.start < seconds { LessonReducer.apply(row.change, to: &lesson) }
            }
            guard let request = LectureDigest.request(for: lesson) else { NSLog("probe: no lines"); return }
            let base = try model.modelProvider()
            let arguments = ProcessInfo.processInfo.arguments
            // 列出服务上的模型，挑出名字像“快速版”的，供选择翻译模型。
            if let names = try? await TextProvider.models(endpoint: base.profile.endpoint, apiKey: base.apiKey) {
                let fast = names.filter { name in ["flash", "turbo", "mini", "lite", "chat", "haiku", "instant", "air"].contains { name.lowercased().contains($0) } }
                NSLog("probe models: %d total; fast-looking: %@", names.count, fast.prefix(60).joined(separator: ", "))
            }
            // 候选模型：当前模型 + --probe-models 逗号分隔的模型；每个按自动写法测一次纪要请求与一次翻译请求。
            var candidates = [base.profile.model]
            if let index = arguments.firstIndex(of: "--probe-models"), index + 1 < arguments.count {
                candidates += arguments[index + 1].split(separator: ",").map(String.init)
            }
            let groups = ParagraphAssembler.groups(for: lesson)
            let translation = groups.count > 2 ? ClassroomTranslation.request(for: groups[2], previous: groups[1], lesson: lesson) : request.user
            for name in candidates {
                for (label, system, user) in [("digest", LectureDigest.systemPrompt, request.user), ("translate", ClassroomTranslation.systemPrompt, translation)] {
                    let provider = TextProvider(profile: ModelProfile(endpoint: base.profile.endpoint, model: name), apiKey: base.apiKey,
                                                thinking: ThinkingControl.detect(model: name) == .glm ? .lowEffort : ThinkingControl.detect(model: name))
                    let started = Date()
                    let marks = ProbeMarks()
                    do {
                        let result = try await provider.run(system: system, user: user) { _ in await marks.thought() } receive: { _ in await marks.spoke() }
                        let parsed = label == "digest" ? (try? LectureDigest.parse(result.text, request: request, now: seconds)) != nil
                                                       : (try? ClassroomTranslation.parse(result.text)) != nil
                        NSLog("probe %@ %@: ok thinking=%@ first-answer=%.1f total=%.1f reasoning=%d answer=%d parsed=%@ | %@", name, label, result.thinkingUsed.rawValue,
                              await marks.answerAt.map { $0.timeIntervalSince(started) } ?? -1, Date().timeIntervalSince(started),
                              result.reasoningCharacters, result.text.count, parsed ? "yes" : "no", String(result.text.prefix(label == "translate" ? 400 : 120)).replacingOccurrences(of: "\n", with: " / "))
                    } catch {
                        NSLog("probe %@ %@: failed after %.1f s: %@", name, label, Date().timeIntervalSince(started), error.localizedDescription)
                    }
                }
            }
        } catch { NSLog("probe failed: %@", error.localizedDescription) }
        NSLog("probe done")
    }

    private actor ProbeMarks {
        var thoughtAt: Date?
        var answerAt: Date?
        func thought() { if thoughtAt == nil { thoughtAt = Date() } }
        func spoke() { if answerAt == nil { answerAt = Date() } }
    }

    private static func report(_ lesson: Lesson) throws {
        let calls = (lesson.aiCalls ?? []).map { call -> [String: Any] in
            ["kind": call.kind, "ok": call.ok, "first": call.firstTokenSeconds ?? -1, "total": call.totalSeconds,
             "in": call.inputCharacters, "out": call.outputCharacters, "error": call.error ?? "", "output": call.output ?? ""]
        }
        let sections = (lesson.digest ?? []).map { section -> [String: Any] in
            ["title": section.title, "start": section.start, "end": section.end, "summary": section.summary,
             "points": section.points.map { ["kind": $0.kind, "text": $0.text, "sources": $0.sources.count] }]
        }
        let paragraphs = ParagraphAssembler.groups(for: lesson).map { group -> [String: Any] in
            let translation = group.paragraphTranslation(in: lesson)
            return ["start": group.lines[0].start, "asr": group.original, "apple": group.lines.compactMap(\.translation).joined(),
                    "engine": translation?.engine ?? "", "english": translation?.english ?? "", "chinese": translation?.text ?? ""]
        }
        let article = (lesson.article ?? []).map { ["start": $0.start, "end": $0.end, "text": $0.text] as [String: Any] }
        let answers = lesson.answers.map { ["question": $0.question, "answer": $0.answer, "live": $0.mediaTime != nil] as [String: Any] }
        let object: [String: Any] = ["title": lesson.title, "paragraphs": paragraphs, "article": article, "answers": answers, "focus": lesson.focus.map { ["topic": $0.topic, "phase": $0.phase, "hint": $0.hint] } ?? [:],
                                     "sections": sections, "calls": calls]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replay-report.json")
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]).write(to: url)
        NSLog("replay report: %@", url.path)
    }
}
#endif
