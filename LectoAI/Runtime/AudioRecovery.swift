import AVFoundation
import LectoAICore

/// 音频文件先落盘，再登记事件；重启时补登已封口但尚未入日志的文件。
enum AudioRecovery {
    nonisolated static func reconcile(_ lesson: Lesson, repository: LessonRepository) async throws {
        let folder = await repository.directory(lesson.id).appendingPathComponent("audio")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let known = Set(lesson.audio.map(\.file))
        for file in files where !known.contains(file.lastPathComponent) && ["m4a", "caf"].contains(file.pathExtension) {
            guard let milliseconds = Int64(file.deletingPathExtension().lastPathComponent.split(separator: "_").first ?? "") else { continue }
            do {
                let audio = try AVAudioFile(forReading: file)
                let duration = Double(audio.length) / audio.processingFormat.sampleRate
                guard duration > 0 else { continue }
                let start = Double(milliseconds) / 1000
                try await repository.append(.chunk(.init(file: file.lastPathComponent, start: start, duration: duration)), to: lesson.id)
                try await repository.append(.gap(.init(start: start, end: start + duration, reason: "恢复未登记音频")), to: lesson.id)
            } catch {
                try await repository.append(.issue("未封口音频保留在 audio/\(file.lastPathComponent)，无法自动恢复。"), to: lesson.id)
            }
        }
        for name in try await repository.missingAudioFiles(lesson.id) {
            let issue = "音频文件缺失：\(name)"
            if !lesson.issues.contains(issue) { try await repository.append(.issue(issue), to: lesson.id) }
        }
        let snapshot = try await repository.load(lesson.id)
        let last = snapshot.lines.map(\.end).max() ?? 0
        if snapshot.duration - last > 0.5, !(snapshot.gaps ?? []).contains(where: { !$0.resolved && $0.end >= snapshot.duration - 0.5 }) {
            try await repository.append(.gap(.init(start: last, end: snapshot.duration, reason: "异常退出后此区间尚未确认识别完整性，可能包含静音")), to: lesson.id)
        }
        try await repository.project(lesson.id)
    }

    nonisolated static func mergedAudio(_ lesson: Lesson, repository: LessonRepository, destination: URL) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CaptureFailure("无法创建录音导出。") }
        let folder = await repository.directory(lesson.id).appendingPathComponent("audio")
        for chunk in lesson.audio.sorted(by: { $0.start < $1.start }) {
            let asset = AVURLAsset(url: folder.appendingPathComponent(chunk.file))
            guard let input = try await asset.loadTracks(withMediaType: .audio).first else { throw CaptureFailure("录音分块无法读取。") }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: input, at: CMTime(seconds: chunk.start, preferredTimescale: 48000))
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw CaptureFailure("无法导出录音。") }
        try await exporter.export(to: destination, as: .m4a)
    }
}
