import Foundation

/// 用到 AI 的功能（A3）。每项可以跟随默认模型，也可以单独指定服务与模型。
public enum AIFeature: String, Codable, CaseIterable, Sendable, Identifiable {
    case translate, summary, digest, answer, notes
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .translate: "课堂翻译"
        case .summary: "总结文章"
        case .digest: "纪要与此刻"
        case .answer: "问答"
        case .notes: "课后整理"
        }
    }
    public var detail: String {
        switch self {
        case .translate: "每段讲完调用一次，最频繁，要快"
        case .summary: "主窗口“总结”页，约 1.5–2 分钟一段"
        case .digest: "右侧助手的分节纪要，约 2 分钟一次"
        case .answer: "你提问时，要理解力强"
        case .notes: "笔记整理，不赶时间，要质量"
        }
    }
    /// 课中自动、频繁调用的功能：总是关闭思考以保证速度。
    public var isRealtime: Bool { self == .translate || self == .summary || self == .digest }
    /// 调用记录里的类型名。
    public var callKind: String {
        switch self {
        case .translate: "translate"
        case .summary: "summary"
        case .digest: "digest"
        case .answer: "answer"
        case .notes: "notes"
        }
    }
}

/// 一个兼容 OpenAI Chat Completions 的服务。密钥按服务分别存在钥匙串，不在这里。
public struct AIService: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var endpoint: String
    /// 关闭思考的参数写法；nil 为按模型名自动判断。
    public var thinking: ThinkingControl?
    public init(id: UUID = UUID(), name: String, endpoint: String, thinking: ThinkingControl? = nil) {
        self.id = id; self.name = name; self.endpoint = endpoint; self.thinking = thinking
    }
}

public struct AIRoute: Codable, Equatable, Sendable {
    public var serviceID: UUID
    public var model: String
    public init(serviceID: UUID, model: String) { self.serviceID = serviceID; self.model = model }
}

/// 服务 → 默认模型 → 各功能覆盖。功能单独设置时覆盖默认（界面 v3 §6.1）。
public struct AIConfiguration: Codable, Equatable, Sendable {
    public var services: [AIService] = []
    public var defaultRoute: AIRoute?
    /// 键为 AIFeature.rawValue。
    public var overrides: [String: AIRoute] = [:]
    /// 问答与课后整理是否允许模型思考（更慢，可能更准）；课中自动功能总是关闭思考。
    public var allowThinking = false
    /// 实际调用中验证可用的思考参数（模型名 → 写法），服务拒绝后自动学到的结果。
    public var learnedThinking: [String: ThinkingControl] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey { case services, defaultRoute, overrides, allowThinking, learnedThinking }

    /// 逐项宽松解码：以后新增字段时，旧版本保存的配置仍能读取。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        services = try container.decodeIfPresent([AIService].self, forKey: .services) ?? []
        defaultRoute = try container.decodeIfPresent(AIRoute.self, forKey: .defaultRoute)
        overrides = try container.decodeIfPresent([String: AIRoute].self, forKey: .overrides) ?? [:]
        allowThinking = try container.decodeIfPresent(Bool.self, forKey: .allowThinking) ?? false
        learnedThinking = try container.decodeIfPresent([String: ThinkingControl].self, forKey: .learnedThinking) ?? [:]
    }

    /// 从 0.3.x 的单一“服务地址 + 模型”迁移：成为第一个服务和默认模型。
    public static func migrated(endpoint: String, model: String) -> AIConfiguration {
        var value = AIConfiguration()
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return value }
        let service = AIService(name: URL(string: trimmed)?.host() ?? "默认服务", endpoint: trimmed)
        value.services = [service]
        if !model.trimmingCharacters(in: .whitespaces).isEmpty { value.defaultRoute = AIRoute(serviceID: service.id, model: model) }
        return value
    }

    public func service(_ id: UUID) -> AIService? { services.first { $0.id == id } }

    /// 功能实际使用的服务与模型：覆盖优先，其次默认。
    public func route(for feature: AIFeature) -> AIRoute? { overrides[feature.rawValue] ?? defaultRoute }

    public func isOverridden(_ feature: AIFeature) -> Bool { overrides[feature.rawValue] != nil }

    /// 这项功能的连接是否完整（地址合法、有模型）；密钥另查钥匙串。
    public func profile(for feature: AIFeature) -> ModelProfile? {
        guard let route = route(for: feature), let service = service(route.serviceID) else { return nil }
        let profile = ModelProfile(endpoint: service.endpoint, model: route.model)
        return (try? profile.url()) == nil ? nil : profile
    }

    /// 关闭思考的方式：课中自动功能与未允许思考时关闭；按服务设置或模型名判断参数写法。
    public func thinking(for feature: AIFeature) -> ThinkingControl {
        guard feature.isRealtime || !allowThinking, let route = route(for: feature) else { return .none }
        return service(route.serviceID)?.thinking ?? learnedThinking[route.model] ?? ThinkingControl.detect(model: route.model)
    }
}

extension ThinkingControl {
    /// 按模型名猜测关闭思考的参数写法；猜不到时不发送任何参数（避免被严格的服务拒绝）。
    public static func detect(model: String) -> ThinkingControl {
        let name = model.lowercased()
        if name.contains("glm") { return .glm }
        if name.contains("qwen") || name.contains("qwq") { return .qwen }
        if name.hasPrefix("o1") || name.hasPrefix("o3") || name.hasPrefix("o4") || name.contains("gpt-5") || name.contains("/o3") || name.contains("/o4") { return .openAI }
        return .none
    }

    public var title: String {
        switch self {
        case .none: "不发送"
        case .glm: "GLM 写法（thinking: disabled）"
        case .qwen: "Qwen 写法（enable_thinking: false）"
        case .openAI: "OpenAI 写法（reasoning_effort: minimal）"
        case .lowEffort: "只降低思考强度（reasoning_effort: low）"
        }
    }
}
