import XCTest
@testable import LectoAICore

final class AudioLevelTests: XCTestCase {
    func testSilenceAndInvalidSamplesAreFinite() {
        for samples: [Float] in [[], [0, 0], [.nan, .infinity]] {
            let value = AudioLevel(samples: samples)
            XCTAssertEqual(value.decibels, -120)
            XCTAssertEqual(value.normalized, 0)
        }
    }

    func testRMSAndClipping() {
        XCTAssertEqual(AudioLevel(samples: [0.5, -0.5]).decibels, -6.0206, accuracy: 0.001)
        XCTAssertEqual(AudioLevel(samples: [2, -2]).normalized, 1)
        XCTAssertEqual(AudioLevel(samples: [1, -1, 1, -1]).decibels, 0)
    }
}
