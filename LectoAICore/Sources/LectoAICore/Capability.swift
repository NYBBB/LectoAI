import Foundation

public enum CapabilityState: String, Codable, Sendable {
    case unavailable, needsSetup, preparing, ready, degraded
}

public struct Capability: Codable, Equatable, Sendable {
    public let state: CapabilityState
    public let reason: String

    public init(state: CapabilityState, reason: String) {
        self.state = state
        self.reason = reason
    }
}

/// 开始采集仅依赖本地必需条件，翻译与云端能力不应阻断原文记录。
public struct CaptureReadiness: Codable, Equatable, Sendable {
    public let source: Capability
    public let transcription: Capability
    public let storage: Capability

    public init(source: Capability, transcription: Capability, storage: Capability) {
        self.source = source
        self.transcription = transcription
        self.storage = storage
    }

    public var canStart: Bool {
        [source, transcription, storage].allSatisfy { $0.state == .ready }
    }
}

public struct BuildReport: Encodable, Sendable {
    public let schemaVersion = 1
    public let stage = "I2"
    public let operatingSystem: String
    public let transcriptionImplemented = true
    public let translationImplemented = true

    public init(operatingSystem: String) {
        self.operatingSystem = operatingSystem
    }
}
