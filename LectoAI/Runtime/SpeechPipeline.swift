import AVFoundation
import Speech
import NaturalLanguage
import LectoAICore

enum PipelineUpdate: Sendable {
    /// 临时文字附带它在课堂中的起点与所属识别运行，界面据此判断是否另起一段（与分段规则一致）。
    case partial(String, start: Double, run: UUID), saved(Lesson), meter(Double, Double), failure(String)
}

/// 转换闭包同步消费输入，所有缓冲都留在同一次非隔离调用内。
private nonisolated func convertPCM(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) throws -> AVAudioPCMBuffer {
    let target = converter.outputFormat
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate + 256)
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw CaptureFailure("音频格式转换失败。") }
    var supplied = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if supplied { status.pointee = .noDataNow; return nil }
        supplied = true; status.pointee = .haveData; return buffer
    }
    if let error { throw error }
    return output
}

/// 每次恢复录音建立新的识别运行，媒体时间由已保存音频决定。
actor SpeechPipeline {
    let repository: LessonRepository
    let lessonID: UUID
    private var runID = UUID()
    private var recognitionOffset: Double
    private var lastFinalEnd: Double
    private var failureGap: RecognitionGap?
    private var restarting = false
    private var appleRestarts = 0
    private var finishing = false
    private var acceptingResults = true
    private let repairOnly: Bool
    private var repairedLines: [TranscriptLine] = []
    private var recoveryFailed = false
    let offset: Double
    let receive: @Sendable (PipelineUpdate) async -> Void
    private var whisperInput: AsyncStream<WhisperWindow>.Continuation?
    private var whisperTask: Task<Void, Never>?
    private var whisperSamples: [Float] = []
    private var whisperStart = 0.0
    private var useWhisper = false
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterRate = 0.0
    private var converterChannels = 0
    private var writer: AVAudioFile?
    private var chunkName = ""
    private var chunkStart: Double = 0
    private var chunkFrames = 0
    private var chunkRate = 0.0
    private var analyzerFrames: Int64 = 0
    private var mediaTime: Double
    private var lastMeterTime = -1.0
    private var asrFailed = false
    private var lastProjection = Date.distantPast

    init(repository: LessonRepository, lessonID: UUID, offset: Double, repairOnly: Bool = false, receive: @escaping @Sendable (PipelineUpdate) async -> Void) {
        self.repository = repository; self.lessonID = lessonID; self.offset = offset; self.mediaTime = offset; self.receive = receive
        self.recognitionOffset = offset; self.lastFinalEnd = offset; self.repairOnly = repairOnly
    }

    func prepare() async throws {
        do {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "forceWhisper") { throw CaptureFailure("开发模式强制后备识别") }
            #endif
            if UserDefaults.standard.double(forKey: "appleRetryAfter") > Date().timeIntervalSince1970 {
                throw CaptureFailure("系统识别暂时冷却，将使用已安装的后备模型。")
            }
            try await prepareApple()
        } catch {
            input?.finish(); input = nil
            resultTask?.cancel(); analysisTask?.cancel()
            await analyzer?.cancelAndFinishNow(); analyzer = nil
            if try await WhisperAssets.shared.installed() != nil { try await prepareWhisper() }
            else { throw error }
        }
    }

    private func prepareWhisper() async throws {
        guard let folder = try await WhisperAssets.shared.installed() else { throw CaptureFailure("请先下载后备模型。") }
        useWhisper = true; asrFailed = false
        converter = nil; converterRate = 0; converterChannels = 0
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
        let (windows, continuation) = AsyncStream<WhisperWindow>.makeStream(bufferingPolicy: .bufferingOldest(3))
        whisperInput = continuation
        let receiver = self
        whisperTask = Task {
            await WhisperRunner.run(folder: folder, windows: windows) { text, start, end in
                await receiver.accept(text: text, start: start, end: end, final: true)
            } failure: { message in await receiver.recognitionFailed(message) }
        }
        try await issue("已切换到 Whisper Large V3 Turbo 后备转写，采用重叠窗口。")
    }

    private func prepareApple() async throws {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { throw CaptureFailure("本机暂不能使用 Apple 英语识别，请在设置中准备后备模型。") }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else { throw CaptureFailure("请先在设置中下载英语识别资源。") }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw CaptureFailure("识别模型没有可用的音频格式。") }
        targetFormat = format
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        input = continuation
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    await self?.accept(text: String(result.text.characters), start: result.range.start.seconds,
                                       end: CMTimeRangeGetEnd(result.range).seconds, final: result.isFinal)
                }
            } catch { await self?.recognitionFailed(error.localizedDescription) }
        }
        analysisTask = Task { [weak self] in
            do { try await analyzer.start(inputSequence: stream) }
            catch { await self?.recognitionFailed(error.localizedDescription) }
        }
    }

    func feed(_ frame: PCMFrame) async throws {
        guard frame.frames > 0 else { return }
        let buffer = try frame.buffer()
        if !repairOnly {
        if let writer, writer.processingFormat != buffer.format { try await seal() }
        if writer == nil {
            chunkName = "\(Int64(mediaTime * 1000))_\(UUID().uuidString).m4a"; chunkStart = mediaTime; chunkFrames = 0; chunkRate = frame.rate
            let url = await repository.directory(lessonID).appendingPathComponent("audio").appendingPathComponent(chunkName)
            var settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: frame.rate, AVNumberOfChannelsKey: frame.channels]
            // 低采样率（如 16/22.05 kHz 单声道录音文件）不支持 96 kbps，交给编码器自动选择，否则导入会直接失败。
            if frame.rate >= 32_000 { settings[AVEncoderBitRateKey] = 96_000 }
            writer = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        try writer?.write(from: buffer)
        chunkFrames += frame.frames
        if Double(chunkFrames) / chunkRate >= 3 { try await seal() }
        }
        let time = mediaTime
        mediaTime += frame.duration
        if asrFailed, var gap = failureGap { gap.end = mediaTime; failureGap = gap }
        if !asrFailed, let targetFormat {
            if converterRate != frame.rate || converterChannels != frame.channels {
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: frame.rate, channels: AVAudioChannelCount(frame.channels), interleaved: false)!
                converter = AVAudioConverter(from: format, to: targetFormat)
                converterRate = frame.rate; converterChannels = frame.channels
            }
            guard let converter else { throw CaptureFailure("音频格式转换失败。") }
            let converted = try convertPCM(buffer, using: converter)
            if useWhisper, let samples = converted.floatChannelData?.pointee {
                if whisperSamples.isEmpty { whisperStart = time - recognitionOffset }
                whisperSamples.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(converted.frameLength)))
                if whisperSamples.count >= 160_000 { try await sendWhisperWindow(final: false) }
            } else if converted.frameLength > 0 {
                // 重采样有余帧；以实际输出帧计时，不能把原始块起点当作重采样块起点。
                let position = CMTime(value: analyzerFrames, timescale: CMTimeScale(targetFormat.sampleRate))
                analyzerFrames += Int64(converted.frameLength)
                if case .dropped = input?.yield(AnalyzerInput(buffer: converted, bufferStartTime: position)) {
                    try await recordGap(start: time, end: mediaTime, reason: "识别输入积压")
                }
            }
        }
        if mediaTime - lastMeterTime > 0.15 {
            lastMeterTime = mediaTime
            await receive(.meter(mediaTime, AudioLevel(samples: Array(frame.samples.prefix(2048))).normalized))
        }
    }

    func importFile(_ url: URL, start: Double = 0, duration: Double? = nil) async throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { throw CaptureFailure("无法读取此音频文件。") }
        file.framePosition = min(file.length, AVAudioFramePosition(start * file.processingFormat.sampleRate))
        let stop = min(file.length, duration.map { file.framePosition + AVAudioFramePosition($0 * file.processingFormat.sampleRate) } ?? file.length)
        while file.framePosition < stop {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, stop - file.framePosition)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            var values: [Float] = []
            for channel in 0..<Int(buffer.format.channelCount) {
                values.append(contentsOf: UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)))
            }
            try await feed(PCMFrame(samples: values, channels: Int(buffer.format.channelCount), interleaved: false, rate: buffer.format.sampleRate))
            // 文件按真实时速输入，与麦克风共用有界识别输入，避免长课灌满内存。
            try await Task.sleep(for: .seconds(Double(buffer.frameLength) / buffer.format.sampleRate))
        }
    }

    func finish() async throws -> Double {
        finishing = true
        try await seal()
        if useWhisper {
            try await sendWhisperWindow(final: true)
            whisperInput?.finish(); whisperInput = nil
            let task = whisperTask
            let (completion, done) = AsyncStream<Bool>.makeStream()
            let waiter = Task { await task?.value; done.yield(true); done.finish() }
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                done.yield(false); done.finish()
            }
            for await completed in completion {
                if !completed {
                    acceptingResults = false; task?.cancel(); recoveryFailed = true
                    try await recordGap(start: lastFinalEnd, end: mediaTime, reason: "后备识别收尾超时")
                }
                break
            }
            waiter.cancel(); timeout.cancel()
        }
        input?.finish(); input = nil
        if let analyzer {
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await analyzer.cancelAndFinishNow()
            }
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            catch { try await recordGap(start: lastFinalEnd, end: mediaTime, reason: "识别收尾未完成：" + error.localizedDescription) }
            timeout.cancel()
        }
        await resultTask?.value
        analysisTask?.cancel()
        if let gap = failureGap { try await saveGap(gap) }
        if repairOnly && recoveryFailed { throw CaptureFailure("补识别未完成，缺口保持待处理。") }
        return mediaTime
    }

    private func sendWhisperWindow(final: Bool) async throws {
        guard !whisperSamples.isEmpty else { return }
        let end = whisperStart + Double(whisperSamples.count) / 16000
        if case .dropped = whisperInput?.yield(WhisperWindow(samples: whisperSamples, start: whisperStart, commitBefore: final ? end : end - 2)) {
            try await recordGap(start: recognitionOffset + whisperStart, end: recognitionOffset + end, reason: "后备识别输入积压")
        }
        if final { whisperSamples.removeAll(keepingCapacity: true) }
        else {
            let retained = min(whisperSamples.count, 64_000)
            whisperStart = end - Double(retained) / 16000
            whisperSamples = Array(whisperSamples.suffix(retained))
        }
    }

    private func seal() async throws {
        guard writer != nil else { return }
        writer = nil
        let lesson = try await repository.append(.chunk(AudioChunk(file: chunkName, start: chunkStart, duration: Double(chunkFrames) / chunkRate)), to: lessonID)
        await receive(.saved(lesson))
    }

    private func accept(text: String, start: Double, end: Double, final: Bool) async {
        guard acceptingResults else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !final { await receive(.partial(text, start: recognitionOffset + max(0, start), run: runID)); return }
        do {
            let globalStart = recognitionOffset + max(0, start)
            let globalEnd = recognitionOffset + max(start, end)
            let current = try await repository.load(lessonID)
            // 仅消除同一时间区间的重放重复，保留老师在其他时间的重复讲解。
            if repairOnly && current.lines.contains(where: { abs($0.start - globalStart) < 1.0 && abs($0.end - globalEnd) < 1.0 && $0.original.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines) }) { return }
            let tokenizer = NLTokenizer(unit: .sentence); tokenizer.string = text
            var sentences: [String] = []
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                // 识别结果常带前导空格；去掉空白后再成句，避免界面与导出出现空行或错位。
                let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                return true
            }
            if sentences.isEmpty { sentences = [text.trimmingCharacters(in: .whitespacesAndNewlines)] }
            // 超长句在逗号、连词处拆成约 20 词以内的短句：更好读，译文也更快出现（S1）。
            sentences = sentences.flatMap { SentenceSplitter.split($0) }
            let total = Double(max(1, sentences.reduce(0) { $0 + $1.count }))
            var cursor = globalStart
            for sentence in sentences {
                let next = min(globalEnd, cursor + (globalEnd - globalStart) * Double(sentence.count) / total)
                var line = TranscriptLine(start: cursor, end: max(cursor + 0.01, next), original: sentence, runID: runID)
                line.engine = useWhisper ? "WhisperKit large-v3-turbo" : "Apple SpeechTranscriber"
                var flags: [String] = []
                if sentence.rangeOfCharacter(from: .letters) == nil { flags.append("缺少有效文字") }
                if current.lines.suffix(10).filter({ $0.original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == sentence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count >= 3 { flags.append("疑似重复识别") }
                line.flags = flags
                if repairOnly { repairedLines.append(line) }
                else {
                    let saved = try await repository.append(.line(line), to: lessonID)
                    await receive(.saved(saved))
                }
                cursor = next
            }
            lastFinalEnd = max(lastFinalEnd, globalEnd)
            if !useWhisper { UserDefaults.standard.removeObject(forKey: "appleRetryAfter") }
            // 事件日志已同步落盘；投影文件只是派生结果，课中限频重建，暂停/结束时会完整重建。
            if Date().timeIntervalSince(lastProjection) > 30 {
                try await repository.project(lessonID); lastProjection = Date()
            }
            await receive(.partial("", start: 0, run: runID))
        } catch { await receive(.failure("文字保存失败：\(error.localizedDescription)")) }
    }

    private func recognitionFailed(_ message: String) async {
        guard !restarting else { return }
        recoveryFailed = true
        asrFailed = true
        if failureGap == nil { failureGap = RecognitionGap(start: lastFinalEnd, end: mediaTime, reason: "识别中断：" + message) }
        if finishing || repairOnly || useWhisper {
            try? await issue("识别中断：\(message)。音频已保留，可课后补识别。")
            return
        }
        restarting = true
        input?.finish(); input = nil
        resultTask?.cancel(); analysisTask?.cancel()
        await analyzer?.cancelAndFinishNow(); analyzer = nil
        recognitionOffset = mediaTime; analyzerFrames = 0; runID = UUID()
        converter = nil; converterRate = 0; converterChannels = 0
        do {
            if appleRestarts == 0 {
                appleRestarts += 1
                do { try await prepareApple(); asrFailed = false }
                catch { try await prepareWhisper() }
            } else { try await prepareWhisper() }
            recognitionOffset = mediaTime
            if useWhisper { UserDefaults.standard.set(Date().addingTimeInterval(1800).timeIntervalSince1970, forKey: "appleRetryAfter") }
            if var gap = failureGap { gap.end = mediaTime; try await saveGap(gap); failureGap = nil }
            try await issue("识别已恢复，中断区间已记录，可在停止后补识别。")
        } catch { try? await issue("识别暂不可用，录音继续保存。请准备后备模型后补识别。") }
        restarting = false
    }

    func repairResult() -> [TranscriptLine] { repairedLines }

    private func recordGap(start: Double, end: Double, reason: String) async throws {
        recoveryFailed = true
        try await saveGap(RecognitionGap(start: start, end: end, reason: reason))
    }
    private func saveGap(_ gap: RecognitionGap) async throws {
        guard gap.end > gap.start else { return }
        if repairOnly { recoveryFailed = true; return }
        let value = try await repository.append(.gap(gap), to: lessonID)
        await receive(.saved(value))
    }

    private func issue(_ text: String) async throws {
        let lesson = try await repository.append(.issue(text), to: lessonID)
        await receive(.saved(lesson))
    }
}
