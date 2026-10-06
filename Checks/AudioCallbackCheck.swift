import AVFoundation
import Synchronization

/// 只使用内存中的合成样本，不打开音频设备或保存录音。
@main
struct AudioCallbackCheck {
    @MainActor static func main() async {
        let received = Mutex<[PCMFrame]>([])
        // 与真实调用一样从主线程创建回调，再由后台线程调用。
        let callback = makeMicrophoneCallback(rate: 48000, channels: 1, interleaved: false) { frame in
            received.withLock { $0.append(frame) }
        }
        await Task.detached { invoke(callback) }.value
        let frames = received.withLock { $0 }
        precondition(frames.count == 1 && frames[0].frames == 256)
        precondition(frames[0].samples.allSatisfy { $0 == 0.25 })
        print("PASS：主线程创建的生产回调在后台接收256个合成样本，无线程隔离崩溃。")
    }

    nonisolated static func invoke(_ callback: (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        precondition(!Thread.isMainThread)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        buffer.frameLength = 256
        for index in 0..<256 { buffer.floatChannelData![0][index] = 0.25 }
        callback(buffer, AVAudioTime(sampleTime: 0, atRate: 48000))
    }
}
