import XCTest
@testable import LectoAICore

final class AIConfigurationTests: XCTestCase {
    func testMigrationAndOverrides() throws {
        var config = AIConfiguration.migrated(endpoint: "https://router.example.com/api/v1", model: "bigmodel/glm-5.3-flash")
        XCTAssertEqual(config.services.count, 1)
        XCTAssertEqual(config.services[0].name, "router.example.com")
        XCTAssertEqual(config.profile(for: .translate)?.model, "bigmodel/glm-5.3-flash")
        // 实时功能总是关闭思考；GLM 按模型名自动选写法。
        XCTAssertEqual(config.thinking(for: .translate), .glm)
        XCTAssertEqual(config.thinking(for: .answer), .glm, "默认不允许思考")
        config.allowThinking = true
        XCTAssertEqual(config.thinking(for: .answer), .none)
        XCTAssertEqual(config.thinking(for: .digest), .glm)

        let other = AIService(name: "另一家", endpoint: "https://api.example.org/v1", thinking: ThinkingControl.none)
        config.services.append(other)
        config.overrides[AIFeature.answer.rawValue] = AIRoute(serviceID: other.id, model: "qwen3-max")
        XCTAssertEqual(config.profile(for: .answer)?.endpoint, "https://api.example.org/v1")
        XCTAssertEqual(config.profile(for: .summary)?.model, "bigmodel/glm-5.3-flash", "未覆盖的功能跟随默认")
        config.allowThinking = false
        XCTAssertEqual(config.thinking(for: .answer), ThinkingControl.none, "服务明确设置为不发送时尊重设置")

        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(AIConfiguration.self, from: data), config)
        XCTAssertNil(AIConfiguration.migrated(endpoint: "", model: "").defaultRoute)
        // 旧版本保存的配置缺少新字段仍能读取。
        let old = try JSONDecoder().decode(AIConfiguration.self, from: Data(#"{"services":[],"overrides":{}}"#.utf8))
        XCTAssertTrue(old.learnedThinking.isEmpty)
        // 学到的写法优先于按模型名猜测。
        config.learnedThinking["bigmodel/glm-5.3-flash"] = .lowEffort
        XCTAssertEqual(config.thinking(for: .translate), .lowEffort)
    }

    func testThinkingDetection() {
        XCTAssertEqual(ThinkingControl.detect(model: "qwen-plus"), .qwen)
        XCTAssertEqual(ThinkingControl.detect(model: "o4-mini"), .openAI)
        XCTAssertEqual(ThinkingControl.detect(model: "deepseek-chat"), ThinkingControl.none)
    }
}
