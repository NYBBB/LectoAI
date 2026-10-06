import Foundation

public struct ModelProfile: Codable, Sendable {
    public var endpoint: String
    public var model: String
    public init(endpoint: String, model: String) { self.endpoint = endpoint; self.model = model }
    public func url() throws -> URL {
        guard let url = URL(string: endpoint), let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, !model.trimmingCharacters(in: .whitespaces).isEmpty,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else { throw LessonError.invalidEndpoint }
        return url.path.hasSuffix("/chat/completions") ? url : url.appendingPathComponent("chat/completions")
    }
}

/// 不跟随重定向，避免把凭据带到用户未配置的地址。
private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// 关闭模型“先思考再回答”的方式。各家兼容接口的参数不同，不认识的参数可能被拒绝，所以按服务选择。
/// 实测 glm-5.3-flash 默认会思考 40 秒以上并把输出额度耗在思考上，纪要全部失败（2026-09-29）。
public enum ThinkingControl: String, Codable, Sendable, CaseIterable {
    /// 不发送任何思考参数。
    case none
    /// 智谱 GLM：`thinking: {type: disabled}`
    case glm
    /// 通义千问等：`enable_thinking: false`
    case qwen
    /// OpenAI 推理模型：`reasoning_effort: minimal`
    case openAI
    /// 始终思考、只能调强度的模型（如经路由的 glm-5.3-flash）：`reasoning_effort: low`
    case lowEffort

    var parameters: [String: Any] {
        switch self {
        case .none: [:]
        case .glm: ["thinking": ["type": "disabled"]]
        case .qwen: ["enable_thinking": false]
        case .openAI: ["reasoning_effort": "minimal"]
        case .lowEffort: ["reasoning_effort": "low"]
        }
    }
}

/// 一次流式调用的结果：正式回答、思考部分的字数（不保存内容）与结束原因。
public struct StreamResult: Sendable {
    public var text: String
    public var reasoningCharacters: Int
    public var finishReason: String?
    /// 实际生效的思考参数（服务拒绝原参数后会自动换一种）。
    public var thinkingUsed: ThinkingControl = .none
}

/// 服务拒绝了思考参数（HTTP 400 且提到思考/推理）。
struct ThinkingRejected: Error { let detail: String }

public struct TextProvider: Sendable {
    public let profile: ModelProfile
    public let apiKey: String
    public var thinking: ThinkingControl
    public var maxTokens: Int
    public init(profile: ModelProfile, apiKey: String, thinking: ThinkingControl = .none, maxTokens: Int = 4000) {
        self.profile = profile; self.apiKey = apiKey; self.thinking = thinking; self.maxTokens = maxTokens
    }

    /// 读取服务的模型列表（GET …/models），用于设置里的模型下拉；不支持时由调用方改为手动填写。
    public static func models(endpoint: String, apiKey: String) async throws -> [String] {
        let chat = try ModelProfile(endpoint: endpoint, model: "list").url()
        let base = chat.path.hasSuffix("/chat/completions") ? chat.deletingLastPathComponent().deletingLastPathComponent() : chat
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.timeoutInterval = 20
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]] else { throw LessonError.api("这个服务没有提供模型列表，请手动填写模型名。") }
        return items.compactMap { $0["id"] as? String }.sorted()
    }

    public func stream(system: String, user: String, receive: @Sendable (String) async -> Void) async throws -> String {
        try await run(system: system, user: user, receive: receive).text
    }

    /// 流式请求。只把正式回答交给 `receive`；思考内容（reasoning_content / reasoning）只计字数。
    /// 流式请求。服务拒绝思考参数时依次改用 `reasoning_effort: low`、不发送参数，各重试一次。
    public func run(system: String, user: String, onReasoning: @Sendable (Int) async -> Void = { _ in },
                    receive: @Sendable (String) async -> Void) async throws -> StreamResult {
        var attempts = [thinking]
        for fallback in [ThinkingControl.lowEffort, .none] where !attempts.contains(fallback) { attempts.append(fallback) }
        var lastRejection = ""
        for control in attempts {
            do {
                var result = try await once(system: system, user: user, thinking: control, onReasoning: onReasoning, receive: receive)
                result.thinkingUsed = control
                return result
            } catch let rejected as ThinkingRejected { lastRejection = rejected.detail; continue }
        }
        throw LessonError.api("服务不接受任何关闭思考的参数：\(lastRejection)")
    }

    private func once(system: String, user: String, thinking: ThinkingControl, onReasoning: @Sendable (Int) async -> Void,
                      receive: @Sendable (String) async -> Void) async throws -> StreamResult {
        var request = URLRequest(url: try profile.url())
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": profile.model, "stream": true, "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": String(user.prefix(28000))]]
        ]
        body.merge(thinking.parameters) { _, new in new }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            var detail = ""
            for try await line in bytes.lines { detail += line; if detail.count > 300 { break } }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let lowered = detail.lowercased()
            if status == 400, thinking != .none, ["思考", "thinking", "reasoning", "effort"].contains(where: { lowered.contains($0) }) {
                throw ThinkingRejected(detail: String(detail.prefix(200)))
            }
            throw LessonError.api("AI 请求失败（HTTP \(status)）\(detail.isEmpty ? "" : "：" + String(detail.prefix(300)))")
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true else {
            throw LessonError.api("此地址未返回流式 Chat Completions，请检查服务兼容性。")
        }
        var output = ""
        var reasoning = 0
        var finish: String?
        var completed = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { completed = true; break }
            guard let data = payload.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = object["error"] {
                throw LessonError.api("服务返回错误：\(String(describing: (error as? [String: Any])?["message"] ?? error).prefix(200))")
            }
            let choice = (object["choices"] as? [[String: Any]])?.first
            if let reason = choice?["finish_reason"] as? String { finish = reason; completed = true }
            if let delta = choice?["delta"] as? [String: Any] {
                if let thought = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !thought.isEmpty {
                    reasoning += thought.count
                    await onReasoning(reasoning)
                }
                if let content = delta["content"] as? String, !content.isEmpty {
                    output += content
                    guard output.count <= 24000 else { throw LessonError.api("回答超过长度上限，已停止。") }
                    await receive(output)
                }
            }
        }
        guard completed else { throw LessonError.api("连接在回答完成前中断，未保存为正式回答。") }
        if output.isEmpty {
            throw LessonError.api(reasoning > 0
                ? "模型只输出了思考过程（\(reasoning) 字），没有给出回答；可在设置里关闭思考或换用更快的模型。"
                : "模型没有返回回答。")
        }
        if let finish, finish != "stop" {
            throw LessonError.api(finish == "length"
                ? "回答被输出上限截断（思考 \(reasoning) 字，回答 \(output.count) 字）；可关闭思考或缩短问题。"
                : "回答未完整结束（\(finish)）。")
        }
        return StreamResult(text: output, reasoningCharacters: reasoning, finishReason: finish)
    }

    public static func context(lines: [TranscriptLine], selected: UUID?, question: String = "") -> String {
        context(lines: lines, selected: selected.map { [$0] } ?? [], question: question)
    }

    /// 选中的一段（多句）优先进入上下文，再按关键词和时间补充。
    public static func context(lines: [TranscriptLine], selected: [UUID], question: String = "") -> String {
        var picked: [TranscriptLine] = []
        for id in selected { if let line = lines.first(where: { $0.id == id }) { picked.append(line) } }
        let terms = question.lowercased().components(separatedBy: .alphanumerics.inverted).filter { $0.count > 2 }
        let ranked = lines.map { line in (line, terms.filter { line.original.lowercased().contains($0) }.count) }
            .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(8).map(\.0)
        for line in ranked + Array(lines.reversed()) where !picked.contains(where: { $0.id == line.id }) { picked.append(line) }
        var remaining = 19000
        var slices: [(Double, String)] = []
        for line in picked {
            guard remaining > 100 else { break }
            let text = String(line.original.prefix(min(4000, remaining - 80)))
            let value = "[\(LineRef.label(line))] \(text)"
            slices.append((line.start, value)); remaining -= value.count
        }
        return slices.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")
    }
}
