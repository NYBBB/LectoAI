import Foundation
import WhisperKit

struct WhisperWindow: Sendable {
    let samples: [Float]
    let start: Double
    let commitBefore: Double
}

/// 推理对象局限于此异步函数；录音线程只提交有界窗口，不等待 Core ML 推理。
enum WhisperRunner {
    nonisolated static func run(folder: URL, windows: AsyncStream<WhisperWindow>,
                                emit: @Sendable (String, Double, Double) async -> Void,
                                failure: @Sendable (String) async -> Void) async {
        do {
            try await WhisperAssets.shared.validate(folder)
            let engine = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: folder,
                                                               verbose: false, prewarm: false, load: true, download: false))
            var committedEnd = 0.0
            let options = DecodingOptions(language: "en", temperatureFallbackCount: 2, skipSpecialTokens: true,
                                          concurrentWorkerCount: 1)
            for await window in windows {
                try Task.checkCancellation()
                let results = try await engine.transcribe(audioArray: window.samples, decodeOptions: options)
                for segment in results.flatMap(\.segments) {
                    let start = window.start + Double(segment.start), end = window.start + Double(segment.end)
                    guard end <= window.commitBefore + 0.1, end > committedEnd + 0.05,
                          segment.noSpeechProb < 0.6, segment.avgLogprob > -1.5 else { continue }
                    await emit(segment.text, max(committedEnd, start), end)
                    committedEnd = end
                }
            }
        } catch is CancellationError {} catch { await failure(error.localizedDescription) }
    }
}
