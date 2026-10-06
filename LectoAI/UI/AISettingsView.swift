import LectoAICore
import SwiftUI

/// 设置 → AI（A3，界面 v3 §6.1）：服务 → 默认模型 → 各功能覆盖。功能单独设置时覆盖默认。
struct AssistantSettings: View {
    @Bindable var model: AppModel
    @State private var editingService: AIService?
    @State private var editingFeature: AIFeature?
    @AppStorage("aiTranslate") private var translate = true
    @AppStorage("aiArticle") private var article = true
    @AppStorage("autoDigest") private var digest = true

    var body: some View {
        Form {
            Section {
                ForEach(model.aiConfig.services) { service in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.name)
                            Text(service.endpoint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(KeyVault.hasKey(service) ? "密钥已保存" : "没有密钥").font(.caption)
                            .foregroundStyle(KeyVault.hasKey(service) ? Color.secondary : Color.orange)
                        Button("编辑…") { editingService = service }
                    }
                }
                Button { editingService = AIService(name: "", endpoint: "https://") } label: { Label("添加服务", systemImage: "plus") }
            } header: {
                Text("服务")
            } footer: {
                Text("兼容 OpenAI Chat Completions 的服务都可以。可以保存多个，例如翻译用一家快而便宜的、问答用一家更强的。密钥分别保存在本机钥匙串，只发往各自的地址。")
            }

            Section {
                RoutePicker(model: model, route: Binding(get: { model.aiConfig.defaultRoute }, set: { model.aiConfig.defaultRoute = $0 }), feature: .answer)
            } header: {
                Text("默认模型")
            } footer: {
                Text("所有功能默认都用它。")
            }

            Section {
                ForEach(AIFeature.allCases) { feature in
                    HStack(spacing: 10) {
                        if let binding = toggle(for: feature) {
                            Toggle("", isOn: binding).labelsHidden().toggleStyle(.checkbox)
                        } else {
                            Image(systemName: "checkmark.square.fill").foregroundStyle(.tertiary).help("问答与整理只在你点击时使用")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                            Text(feature.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(routeSummary(feature)).font(.caption).foregroundStyle(model.aiConfig.profile(for: feature) == nil ? Color.red : Color.secondary)
                            .lineLimit(1)
                        Button("设置…") { editingFeature = feature }
                    }
                }
                Toggle("问答与课后整理允许模型思考", isOn: Binding(get: { model.aiConfig.allowThinking }, set: { model.aiConfig.allowThinking = $0 }))
            } header: {
                Text("各功能（未单独设置时跟随默认）")
            } footer: {
                Text("课中的翻译、总结和纪要总是请模型不要先思考，否则一次要等 40 秒以上（2026-09-29 实测）。每次调用的耗时与失败原因可在 AI 助手 ⋯ → AI 调用记录 里查看。")
            }

            Section {
                HStack {
                    Button("导入连接配置…") { model.importProfile() }
                    Button("导出连接配置…") { model.exportProfile() }
                }
            } footer: {
                Text("配置文件包含服务地址、模型和各功能设置，不包含密钥。")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingService) { service in ServiceEditor(model: model, service: service) }
        .sheet(item: $editingFeature) { feature in FeatureEditor(model: model, feature: feature) }
    }

    private func toggle(for feature: AIFeature) -> Binding<Bool>? {
        switch feature {
        case .translate: $translate
        case .summary: $article
        case .digest: $digest
        case .answer, .notes: nil
        }
    }

    private func routeSummary(_ feature: AIFeature) -> String {
        guard let route = model.aiConfig.route(for: feature) else { return "未设置" }
        let service = model.aiConfig.service(route.serviceID)?.name ?? "服务已删除"
        return model.aiConfig.isOverridden(feature) ? "\(service) · \(route.model)" : "跟随默认 · \(route.model)"
    }
}

/// 选择服务与模型，可读取模型列表并测试首字延迟。
private struct RoutePicker: View {
    @Bindable var model: AppModel
    @Binding var route: AIRoute?
    let feature: AIFeature
    @State private var models: [String] = []
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        let services = model.aiConfig.services
        Picker("服务", selection: Binding(get: { route?.serviceID }, set: { id in
            if let id { route = AIRoute(serviceID: id, model: route?.model ?? ""); models = [] }
        })) {
            if route == nil { Text("请选择").tag(UUID?.none) }
            ForEach(services) { Text($0.name).tag(Optional($0.id)) }
        }
        HStack {
            TextField("模型", text: Binding(get: { route?.model ?? "" }, set: { value in
                if let id = route?.serviceID ?? services.first?.id { route = AIRoute(serviceID: id, model: value) }
            }), prompt: Text("例如 bigmodel/glm-5.3-flash"))
            Menu {
                if models.isEmpty { Button("读取模型列表") { loadModels() } }
                ForEach(models, id: \.self) { name in
                    Button(name) { if let id = route?.serviceID { route = AIRoute(serviceID: id, model: name) } }
                }
            } label: { Image(systemName: "list.bullet") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("从服务读取可用模型")
                .disabled(route == nil)
            Button(busy ? "测试中…" : "测试") { test() }.disabled(busy || route == nil)
        }
        if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
    }

    private var service: AIService? { route.flatMap { model.aiConfig.service($0.serviceID) } }

    private func loadModels() {
        guard let service else { return }
        busy = true; status = String(localized: "正在读取模型列表…")
        Task {
            defer { busy = false }
            do {
                models = try await TextProvider.models(endpoint: service.endpoint, apiKey: try KeyVault.read(service: service))
                status = models.isEmpty ? String(localized: "服务没有返回模型。") : String(localized: "共 \(models.count) 个模型，点右侧列表选择。")
            } catch { status = error.localizedDescription }
        }
    }

    /// 发一句极短的测试，显示首字延迟与总耗时（按这项功能的思考设置）。
    private func test() {
        guard let route, let service else { return }
        busy = true; status = String(localized: "正在测试…")
        let thinking = feature.isRealtime || !model.aiConfig.allowThinking ? (service.thinking ?? ThinkingControl.detect(model: route.model)) : .none
        Task {
            defer { busy = false }
            do {
                let provider = TextProvider(profile: ModelProfile(endpoint: service.endpoint, model: route.model),
                                            apiKey: try KeyVault.read(service: service), thinking: thinking, maxTokens: 200)
                let started = Date()
                let first = FirstMark()
                let result = try await provider.run(system: "连接测试。", user: "只回复：好") { _ in await first.mark() } receive: { _ in await first.mark() }
                let firstSeconds = await first.at.map { $0.timeIntervalSince(started) } ?? 0
                let thought = result.reasoningCharacters > 0 ? String(localized: "；模型先思考了 \(result.reasoningCharacters) 字，建议换写法或换模型") : ""
                status = String(format: String(localized: "连接成功：首字 %.1f 秒，共 %.1f 秒"), firstSeconds, Date().timeIntervalSince(started)) + thought
            } catch { status = error.localizedDescription }
        }
    }
}

private actor FirstMark {
    var at: Date?
    func mark() { if at == nil { at = Date() } }
}

/// 添加或编辑服务：名称、地址、密钥、关闭思考的写法。
private struct ServiceEditor: View {
    @Bindable var model: AppModel
    @State var service: AIService
    @State private var key = ""
    @State private var status = ""
    @Environment(\.dismiss) private var dismiss

    private var isNew: Bool { !model.aiConfig.services.contains { $0.id == service.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "添加服务" : "编辑服务").font(.title2.weight(.semibold))
            Form {
                TextField("名称", text: $service.name, prompt: Text("例如 胜算云"))
                TextField("服务地址", text: $service.endpoint, prompt: Text("https://api.openai.com/v1"))
                SecureField("API 密钥", text: $key, prompt: Text(KeyVault.hasKey(service) ? "已保存，留空则不修改" : "sk-…"))
                Picker("关闭思考的写法", selection: $service.thinking) {
                    Text("按模型名自动判断").tag(ThinkingControl?.none)
                    ForEach(ThinkingControl.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
            }
            .formStyle(.grouped)
            Text("不同服务关闭“先思考再回答”的参数写法不同；测试时如果提示模型先思考了很多字，换一种写法再测。")
                .font(.caption).foregroundStyle(.secondary)
            if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.red) }
            HStack {
                if !isNew {
                    Button("删除服务", role: .destructive) { remove() }
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(service.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func save() {
        do {
            _ = try ModelProfile(endpoint: service.endpoint, model: "check").url()
            if let old = model.aiConfig.service(service.id), old.endpoint != service.endpoint, key.isEmpty {
                // 地址变了：旧密钥不能发往新地址，必须重新填写。
                try KeyVault.write("", service: old)
            }
            if !key.isEmpty { try KeyVault.write(key, service: service) }
            if let index = model.aiConfig.services.firstIndex(where: { $0.id == service.id }) { model.aiConfig.services[index] = service }
            else {
                model.aiConfig.services.append(service)
                if model.aiConfig.defaultRoute == nil { model.aiConfig.defaultRoute = AIRoute(serviceID: service.id, model: "") }
            }
            dismiss()
        } catch { status = error.localizedDescription }
    }

    private func remove() {
        try? KeyVault.write("", service: service)
        model.aiConfig.services.removeAll { $0.id == service.id }
        if model.aiConfig.defaultRoute?.serviceID == service.id { model.aiConfig.defaultRoute = nil }
        model.aiConfig.overrides = model.aiConfig.overrides.filter { $0.value.serviceID != service.id }
        dismiss()
    }
}

/// 某项功能：跟随默认或单独设置，并显示本堂课的调用情况。
private struct FeatureEditor: View {
    @Bindable var model: AppModel
    let feature: AIFeature
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(feature.title).font(.title2.weight(.semibold))
            Text(feature.detail).foregroundStyle(.secondary)
            Form {
                Picker("使用", selection: Binding(get: { model.aiConfig.isOverridden(feature) }, set: { custom in
                    model.aiConfig.overrides[feature.rawValue] = custom ? model.aiConfig.defaultRoute : nil
                })) {
                    Text("跟随默认").tag(false)
                    Text("单独设置").tag(true)
                }
                .pickerStyle(.segmented)
                if model.aiConfig.isOverridden(feature) {
                    RoutePicker(model: model, route: Binding(get: { model.aiConfig.overrides[feature.rawValue] },
                                                             set: { model.aiConfig.overrides[feature.rawValue] = $0 }), feature: feature)
                } else if let route = model.aiConfig.defaultRoute {
                    LabeledContent("默认", value: "\(model.aiConfig.service(route.serviceID)?.name ?? "") · \(route.model)")
                }
            }
            .formStyle(.grouped)
            Text(usage).font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var usage: String {
        let calls = (model.lesson?.aiCalls ?? []).filter { $0.kind == feature.callKind }
        guard !calls.isEmpty else { return String(localized: "当前打开的课堂还没有用到这项功能。") }
        let failed = calls.filter { !$0.ok }.count
        let average = calls.map(\.totalSeconds).reduce(0, +) / Double(calls.count)
        return String(format: String(localized: "当前课堂：调用 %d 次，失败 %d 次，平均 %.1f 秒。"), calls.count, failed, average)
    }
}
