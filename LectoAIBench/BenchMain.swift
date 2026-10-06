import Foundation
import AVFoundation
import Speech
import Translation
import LectoAICore

private struct MeasuredLine: Codable, Sendable {
    var start: Double
    var end: Double
    var original: String
    var observedAfterSeconds: Double
    var translation: String?
}
private struct ReplayReport: Codable {
    var mode = "最快文件分析；不作为实时延迟测量"
    var duration: Double
    var processingSeconds: Double
    var realTimeFactor: Double
    var firstResultSeconds: Double?
    var lines: [MeasuredLine]
    var warnings: [String]
}

@main
struct BenchMain {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if arguments == ["--diagnostics"] {
            FileHandle.standardOutput.write(try encoder.encode(BuildReport(operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString))); print(); return
        }
        // WhisperKit：--whisper <file|chunk10|stream> --model <文件夹> --audio <音频> --output <报告> [--limit 秒]
        if arguments.first == "--whisper", arguments.count >= 8 {
            let value = { (name: String) in arguments.firstIndex(of: name).map { arguments[$0 + 1] } }
            let report = try await WhisperBench.run(mode: arguments[1], audio: URL(fileURLWithPath: value("--audio")!),
                                                    modelFolder: URL(fileURLWithPath: value("--model")!), limit: value("--limit").flatMap(Double.init))
            try encoder.encode(report).write(to: URL(fileURLWithPath: value("--output")!), options: .withoutOverwriting)
            print("报告已保存：\(value("--output")!)"); return
        }
        guard arguments.count >= 4, arguments[0] == "--audio", arguments[2] == "--output" else {
            print("LectoAIBench --diagnostics\nLectoAIBench --audio /path/lecture.m4a --output /path/report.json [--translate]")
            if !arguments.isEmpty { exit(64) }; return
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[1]))
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { throw LessonError.api("本机不支持英语识别。") }
        let module = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw LessonError.api("请先在 App 中准备英语识别资源。") }
        let analyzer = SpeechAnalyzer(modules: [module])
        let started = Date()
        // 结果消费与文件分析同时进行；报告按媒体时间保存，不上传音频。
        let collector = Task { () throws -> [MeasuredLine] in
            var lines: [MeasuredLine] = []
            for try await result in module.results where result.isFinal {
                lines.append(MeasuredLine(start: result.range.start.seconds, end: CMTimeRangeGetEnd(result.range).seconds,
                                          original: String(result.text.characters), observedAfterSeconds: Date().timeIntervalSince(started)))
            }
            return lines
        }
        do { try await analyzer.start(inputAudioFile: file, finishAfterFile: true) }
        catch { collector.cancel(); await analyzer.cancelAndFinishNow(); throw error }
        var lines = try await collector.value
        let processing = Date().timeIntervalSince(started)
        var warnings: [String] = []
        if arguments.contains("--translate") {
            let source = Locale.Language(identifier: "en"), target = Locale.Language(identifier: "zh-Hans")
            if await LanguageAvailability().status(from: source, to: target) == .installed {
                let session = TranslationSession(installedSource: source, target: target)
                for index in lines.indices {
                    do { lines[index].translation = try await session.translate(lines[index].original).targetText }
                    catch { warnings.append("翻译中断：" + error.localizedDescription); break }
                }
            } else { warnings.append("未安装翻译资源，报告仅包含原文。") }
        }
        let report = ReplayReport(duration: duration, processingSeconds: processing, realTimeFactor: processing / max(duration, 0.001),
                                  firstResultSeconds: lines.first?.observedAfterSeconds, lines: lines, warnings: warnings)
        // 报告包含课堂原文，输出路径必须由调用者明确指定，已有文件不覆盖。
        try encoder.encode(report).write(to: URL(fileURLWithPath: arguments[3]), options: .withoutOverwriting)
        print("报告已保存：\(arguments[3])")
    }
}
