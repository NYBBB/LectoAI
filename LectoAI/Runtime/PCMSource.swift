import AVFoundation
import CoreAudio
import Synchronization

struct PCMFrame: Sendable {
    let samples: [Float]
    let channels: Int
    let interleaved: Bool
    let rate: Double
    var frames: Int { samples.count / max(1, channels) }
    var duration: Double { Double(frames) / rate }

    func buffer() throws -> AVAudioPCMBuffer {
        guard frames > 0, rate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let pointers = buffer.floatChannelData else { throw CaptureFailure("无法建立音频缓冲。") }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels {
            for frame in 0..<frames {
                pointers[channel][frame] = samples[interleaved ? frame * channels + channel : channel * frames + frame]
            }
        }
        return buffer
    }
}

struct CaptureFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class CaptureOverflow: Sendable {
    let flag = Mutex(false)
}

private nonisolated func pcmCopy(_ list: UnsafePointer<AudioBufferList>, rate: Double, channels: Int, interleaved: Bool) -> PCMFrame {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
    var samples: [Float] = []
    samples.reserveCapacity(buffers.reduce(0) { $0 + Int($1.mDataByteSize) / 4 })
    for buffer in buffers {
        if let data = buffer.mData {
            samples.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(buffer.mDataByteSize) / 4))
        }
    }
    return PCMFrame(samples: samples, channels: channels, interleaved: interleaved, rate: rate)
}

/// 在非隔离上下文建立可跨线程回调，避免继承界面主线程隔离。
nonisolated func makeMicrophoneCallback(rate: Double, channels: Int, interleaved: Bool,
                                        send: @escaping @Sendable (PCMFrame) -> Void) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
    { buffer, _ in
        send(pcmCopy(buffer.audioBufferList, rate: rate, channels: channels, interleaved: interleaved))
    }
}

/// 音频回调只拷贝投递；缓冲满时显式中断采集，不静默丢弃课堂声音。
@MainActor
final class PCMSource {
    var onInterruption: (@MainActor @Sendable (String) -> Void)?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var engine: AVAudioEngine?
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var proc: AudioDeviceIOProcID?
    private var sink: AsyncStream<PCMFrame>.Continuation?
    let overflow = CaptureOverflow()

    func start(system: Bool) async throws -> AsyncStream<PCMFrame> {
        let (stream, continuation) = AsyncStream<PCMFrame>.makeStream(bufferingPolicy: .bufferingOldest(256))
        sink = continuation
        let overflow = self.overflow
        let send: @Sendable (PCMFrame) -> Void = { frame in
            if case .dropped = continuation.yield(frame) { overflow.flag.withLock { $0 = true } }
        }
        do {
            if system { try startSystem(send: send) }
            else {
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw CaptureFailure("请在系统设置中允许 LectoAI 使用麦克风。") }
                let engine = AVAudioEngine()
                let node = engine.inputNode
                let format = node.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else { throw CaptureFailure("麦克风格式不可用。") }
                let rate = format.sampleRate, channels = Int(format.channelCount), interleaved = format.isInterleaved
                node.installTap(onBus: 0, bufferSize: 2048, format: format,
                                block: makeMicrophoneCallback(rate: rate, channels: channels, interleaved: interleaved, send: send))
                self.engine = engine
                try engine.start()
            }
            return stream
        } catch { stop(); throw error }
    }

    func stop() {
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil
        if let proc { AudioDeviceStop(device, proc); AudioDeviceDestroyIOProcID(device, proc) }
        proc = nil
        if device != 0 { AudioHardwareDestroyAggregateDevice(device); device = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        if let outputListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, outputListener)
            self.outputListener = nil
        }
        sink?.finish(); sink = nil
    }

    private func startSystem(send: @escaping @Sendable (PCMFrame) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "LectoAI Classroom"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap))
        var format = AudioStreamBasicDescription()
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format))
        guard format.mBitsPerChannel == 32, format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { throw CaptureFailure("系统音频格式暂不支持。") }
        let properties: [String: Any] = [kAudioAggregateDeviceNameKey: "LectoAI Classroom",
            kAudioAggregateDeviceUIDKey: UUID().uuidString, kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]]
        try check(AudioHardwareCreateAggregateDevice(properties as CFDictionary, &device))
        let rate = format.mSampleRate, channels = Int(format.mChannelsPerFrame)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { @Sendable _, input, _, _, _ in
            send(pcmCopy(input, rate: rate, channels: channels, interleaved: interleaved))
        })
        try check(AudioDeviceStart(device, proc))
        var output = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.onInterruption?("系统输出设备已变化，录音已暂停；检查音源后继续。") }
        }
        try check(AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &output, .main, listener))
        outputListener = listener
    }

    private func check(_ status: OSStatus) throws {
        guard status == 0 else { throw CaptureFailure("音频启动失败（\(status)），请检查系统音频权限或设备。") }
    }
}
