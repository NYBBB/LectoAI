import XCTest
@testable import LectoAICore

final class CaptureReadinessTests: XCTestCase {
    func testEachMissingPrerequisiteBlocksCapture() {
        let ready = Capability(state: .ready, reason: "")
        for state in [CapabilityState.unavailable, .needsSetup, .preparing, .degraded] {
            let blocked = Capability(state: state, reason: "测试条件")
            XCTAssertFalse(CaptureReadiness(source: blocked, transcription: ready, storage: ready).canStart)
            XCTAssertFalse(CaptureReadiness(source: ready, transcription: blocked, storage: ready).canStart)
            XCTAssertFalse(CaptureReadiness(source: ready, transcription: ready, storage: blocked).canStart)
        }
        XCTAssertTrue(CaptureReadiness(source: ready, transcription: ready, storage: ready).canStart)
    }

    func testReadinessRoundTripPreservesBlockingReason() throws {
        let value = CaptureReadiness(
            source: .init(state: .ready, reason: ""),
            transcription: .init(state: .needsSetup, reason: "需要语言资源"),
            storage: .init(state: .ready, reason: "")
        )
        let restored = try JSONDecoder().decode(CaptureReadiness.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored, value)
        XCTAssertFalse(restored.canStart)
    }
}
