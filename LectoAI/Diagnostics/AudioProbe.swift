#if DEBUG
import AVFoundation
import CoreAudio
import LectoAICore
import Observation

private struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 回调只复制有限样本并投递；计算和界面更新在消费端完成。
private nonisolated func copyMeterSamples(_ buffers: UnsafePointer<AudioBufferList>) -> [Float] {
    var samples: [Float] = []
    samples.reserveCapacity(4096)
    for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers)) {
        guard let data = buffer.mData else { continue }
        let count = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, 4096 - samples.count)
        samples.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        if samples.count == 4096 { break }
    }
    return samples
}

@MainActor @Observable
final class AudioProbe {
    private(set) var running = false
    private(set) var starting = false
    private(set) var source = "未试音"
    private(set) var message = "点击试音后才会请求相应音源权限；15 秒后自动停止。"
    private(set) var level = AudioLevel(samples: [])
    private(set) var receivedAudio = false
    private(set) var heardSignal = false
    private var engine: AVAudioEngine?
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var consumer: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()

    func startMicrophone() async {
        guard !starting, !running else { return }
        starting = true
        let token = UUID()
        generation = token
        defer { if generation == token { starting = false } }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard generation == token else { return }
        guard granted else { message = "麦克风未授权。请在系统设置 → 隐私与安全性 → 麦克风中允许 LectoAI。"; return }
        do {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
                throw ProbeFailure(message: "当前麦克风没有可用的 Float32 音频格式。")
            }
            let sink = beginMeter(source: "麦克风")
            self.engine = engine
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
                sink.yield(copyMeterSamples(buffer.audioBufferList))
            }
            try engine.start()
            running = true
            scheduleStop()
        } catch { stop(); message = error.localizedDescription }
    }

    func startSystemAudio() {
        guard !starting, !running else { return }
        starting = true
        defer { starting = false }
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.name = "LectoAI 15-second audio probe"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tapID), "创建系统音频采集")
            var format = AudioStreamBasicDescription()
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "读取音频格式")
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else {
                throw ProbeFailure(message: "此系统音频格式暂不支持电平检查。")
            }
            let properties: [String: Any] = [
                kAudioAggregateDeviceNameKey: "LectoAI Probe",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                   kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(properties as CFDictionary, &aggregateID), "创建临时音频设备")
            let sink = beginMeter(source: "系统音频")
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil) { @Sendable _, input, _, _, _ in
                sink.yield(copyMeterSamples(input))
            }, "建立音频回调")
            try check(AudioDeviceStart(aggregateID, ioProc), "启动系统音频")
            running = true
            scheduleStop()
        } catch { stop(); message = error.localizedDescription }
    }

    func stop() {
        generation = UUID()
        starting = false
        deadline?.cancel(); deadline = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        if let ioProc, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProc)
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
        }
        ioProc = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
        continuation?.finish(); continuation = nil
        consumer?.cancel(); consumer = nil
        if running {
            message = heardSignal ? "试音结束：收到非静音信号。未保存录音。" : receivedAudio ? "收到音频回调，但没有明显声音。请确认音源正在发声；这不等于权限验证通过。" : "未收到音频回调，请检查权限和音源设备。"
        }
        running = false
        level = AudioLevel(samples: [])
    }

    private func beginMeter(source: String) -> AsyncStream<[Float]>.Continuation {
        self.source = source
        receivedAudio = false; heardSignal = false
        message = "试音中，不保存录音。请让所选音源发声。"
        let (stream, sink) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = sink
        consumer = Task { [weak self] in
            for await samples in stream {
                guard !Task.isCancelled else { break }
                guard !samples.isEmpty else { continue }
                self?.receivedAudio = true
                let value = AudioLevel(samples: samples)
                self?.level = value
                if value.decibels > -60 { self?.heardSignal = true }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
        }
        return sink
    }

    private func scheduleStop() {
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.stop()
        }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw ProbeFailure(message: "\(operation)失败（OSStatus \(status)）。请检查系统音频权限和设备；尚未证明沙盒内采集可行。")
        }
    }
}
#endif
