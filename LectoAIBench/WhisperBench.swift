import AVFoundation
import Foundation
import WhisperKit

/// WhisperKit 识别测评（S2）：整段转写测准确率与速度；按真实时间节奏模拟“流式”和“10 秒切片”测延迟与负载。
/// 只读输入音频与本机模型文件夹，不联网下载。
enum WhisperBench {
    struct Segment: Codable { var start: Double; var end: Double; var text: String; var observedAfterSeconds: Double }
    struct Report: Codable {
        var mode: String
        var model: String
        var audioSeconds: Double
        var wallSeconds: Double
        var realTimeFactor: Double
        var inferenceCount: Int
        var meanInferenceSeconds: Double
        var maxInferenceSeconds: Double
        /// 按真实节奏模拟时：一段话说完到文字出现的平均/最大延迟。
        var meanLatencySeconds: Double?
        var maxLatencySeconds: Double?
        var segments: [Segment]
    }

    static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(file.length) * 16000 / file.processingFormat.sampleRate) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    static func run(mode: String, audio: URL, modelFolder: URL, limit: Double?) async throws -> Report {
        var all = try samples(audio)
        if let limit { all = Array(all.prefix(Int(limit * 16000))) }
        let seconds = Double(all.count) / 16000
        let engine = try await WhisperKit(WhisperKitConfig(modelFolder: modelFolder.path, tokenizerFolder: modelFolder,
                                                           verbose: false, prewarm: true, load: true, download: false))
        let options = DecodingOptions(language: "en", temperatureFallbackCount: 2, skipSpecialTokens: true, concurrentWorkerCount: 1)
        var inferences: [Double] = []
        var segments: [Segment] = []
        var latencies: [Double] = []
        let started = Date()
        switch mode {
        case "file":
            // 一次性整段转写（WhisperKit 内部按 30 秒窗口切分）：衡量准确率与最快速度。
            let t = Date()
            let results = try await engine.transcribe(audioArray: all, decodeOptions: options)
            inferences.append(Date().timeIntervalSince(t))
            for segment in results.flatMap(\.segments) {
                segments.append(Segment(start: Double(segment.start), end: Double(segment.end), text: segment.text, observedAfterSeconds: Date().timeIntervalSince(started)))
            }
        case "chunk10":
            // App 现有后备方式：每攒 10 秒识别一次，保留 4 秒重叠，按真实时间节奏送入。
            var committed = 0.0
            var cursor = 0
            var windowStart = 0
            while cursor < all.count {
                let next = min(all.count, cursor + 160_000)
                let audioNow = Double(next) / 16000
                let wait = audioNow - Date().timeIntervalSince(started)
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                let t = Date()
                let results = try await engine.transcribe(audioArray: Array(all[windowStart..<next]), decodeOptions: options)
                inferences.append(Date().timeIntervalSince(t))
                let offset = Double(windowStart) / 16000
                let commitBefore = next == all.count ? audioNow : audioNow - 2
                for segment in results.flatMap(\.segments) {
                    let s = offset + Double(segment.start), e = offset + Double(segment.end)
                    guard e <= commitBefore + 0.1, e > committed + 0.05 else { continue }
                    let seen = Date().timeIntervalSince(started)
                    segments.append(Segment(start: s, end: e, text: segment.text, observedAfterSeconds: seen))
                    latencies.append(seen - e); committed = e
                }
                cursor = next
                windowStart = max(0, next - 64_000)
            }
        default:
            // 流式模拟：每 1 秒对最近最多 20 秒重新识别（与 AudioStreamTranscriber 的做法相同），
            // 结束早于窗口末尾 2 秒的句子视为定稿。衡量出字延迟与持续负载。
            var committed = 0.0
            var cursor = 16_000
            while cursor <= all.count {
                let audioNow = Double(cursor) / 16000
                let wait = audioNow - Date().timeIntervalSince(started)
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                let windowStart = max(Int(committed * 16000), cursor - 320_000)
                let t = Date()
                let results = try await engine.transcribe(audioArray: Array(all[windowStart..<cursor]), decodeOptions: options)
                inferences.append(Date().timeIntervalSince(t))
                let offset = Double(windowStart) / 16000
                let final = cursor >= all.count
                for segment in results.flatMap(\.segments) {
                    let s = offset + Double(segment.start), e = offset + Double(segment.end)
                    guard final || e <= audioNow - 2, e > committed + 0.05 else { continue }
                    let seen = Date().timeIntervalSince(started)
                    segments.append(Segment(start: s, end: e, text: segment.text, observedAfterSeconds: seen))
                    latencies.append(seen - e); committed = e
                }
                if final { break }
                cursor = min(all.count, cursor + 16_000)
            }
        }
        let wall = Date().timeIntervalSince(started)
        return Report(mode: mode, model: modelFolder.lastPathComponent, audioSeconds: seconds, wallSeconds: wall,
                      realTimeFactor: inferences.reduce(0, +) / max(seconds, 0.001), inferenceCount: inferences.count,
                      meanInferenceSeconds: inferences.reduce(0, +) / Double(max(1, inferences.count)), maxInferenceSeconds: inferences.max() ?? 0,
                      meanLatencySeconds: latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count),
                      maxLatencySeconds: latencies.max(), segments: segments)
    }
}
