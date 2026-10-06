import XCTest
@testable import LectoAICore

final class SentenceSplitterTests: XCTestCase {
    func testShortSentencesStayWhole() {
        XCTAssertEqual(SentenceSplitter.split("The key idea is that exec never returns on success."), ["The key idea is that exec never returns on success."])
    }

    func testLongSentenceSplitsAtCommasAndKeepsAllWords() {
        let text = "So I want to, I will definitely give you a homework reminder before the deadline, but I want you to remember that this will be the part that will correspond with the coding question later."
        let pieces = SentenceSplitter.split(text)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0.split(separator: " ").count <= 20 })
        XCTAssertEqual(pieces.joined(separator: " "), text, "拆分不丢词、不改词")
        XCTAssertTrue(pieces[0].hasSuffix(","), "优先在逗号处断开")
    }

    func testNoPunctuationFallsBackToConjunctionOrWordCount() {
        let text = (1...45).map { $0 == 22 ? "because" : "word\($0)" }.joined(separator: " ")
        let pieces = SentenceSplitter.split(text)
        XCTAssertTrue(pieces.allSatisfy { $0.split(separator: " ").count <= 20 })
        XCTAssertEqual(pieces.joined(separator: " "), text)
    }
}
