import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit
import CapturePointCore

enum RecordingService {
    static let toolPath = CaptureService.toolPath

    static func start(
        mode: CaptureMode,
        destination: URL,
        microphone: Bool,
        playSound: Bool,
        includeCursor: Bool,
        showClicks: Bool,
        timeLimitSeconds: Int,
        onExit: @escaping () -> Void
    ) throws -> Process {
        guard CaptureService.toolExists else { throw CaptureError.missingTool }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)

        var args: [String] = ["-v"]
        switch mode {
        case .selection:
            args.append(contentsOf: ["-i", "-s"])
        case .window:
            args.append(contentsOf: ["-i", "-w"])
        case .fullScreen:
            break
        case .mainDisplay:
            args.append("-m")
        }
        if microphone { args.append("-g") }
        if includeCursor { args.append("-C") }
        if showClicks { args.append("-k") }
        if !playSound { args.append("-x") }
        if timeLimitSeconds > 0 {
            args.append("-V")
            args.append(String(timeLimitSeconds))
        }
        args.append(destination.path)

        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Install the handler before launch so a process that exits immediately
        // is still reported.
        process.terminationHandler = { _ in onExit() }
        try process.run()
        return process
    }

    static func interrupt(_ process: Process) {
        guard process.isRunning else { return }
        process.interrupt()
    }

    static func waitUntilExit(_ process: Process, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    /// Waits until `url` has grown past a header so capture has actually begun
    /// (after the user clicks a window, not when the picker appears).
    /// Returns `nil` if the file never appears — `screencapture -v` often writes
    /// nothing until it stops, so a timeout must not be treated as t0.
    static func waitForFileData(_ url: URL, minSize: Int64 = 64_000, timeout: TimeInterval = 180) async -> Date? {
        let start = Date()
        var last: Int64 = 0
        var grew = 0
        while Date().timeIntervalSince(start) < timeout {
            if Task.isCancelled { return nil }
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value {
                if size > last {
                    grew += 1
                    last = size
                }
                if size >= minSize && grew >= 2 {
                    return Date()
                }
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return nil
    }

    struct MuxResult {
        var includedSystemAudio = false
        var includedMicrophone = false
    }

    /// Mixes on-screen audio and an optional microphone file into `video`.
    /// Audio already stored in `video` (the microphone from `screencapture -g`)
    /// is kept. The export runs without blocking the caller.
    static func mux(
        video: URL,
        systemAudio: URL?,
        systemAudioLead: TimeInterval,
        microphone: URL?,
        to output: URL,
        treatEmbeddedAudioAsMicrophone: Bool = false
    ) async throws -> MuxResult {
        let videoAsset = AVURLAsset(url: video)
        let videoDuration = try await videoAsset.load(.duration)
        guard videoDuration.isValid, videoDuration.isNumeric, videoDuration.seconds > 0 else {
            throw CaptureError.recordingFailed("Recording has no duration yet.")
        }
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw CaptureError.recordingFailed("Recording has no video track.")
        }

        let mix = AVMutableComposition()
        let videoComp = mix.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let videoRange = try await videoTrack.load(.timeRange)
        let videoSpan = CMTimeMinimum(videoDuration, videoRange.duration)
        try videoComp?.insertTimeRange(CMTimeRange(start: videoRange.start, duration: videoSpan), of: videoTrack, at: .zero)

        var result = MuxResult()
        let embeddedAudio = try await videoAsset.loadTracks(withMediaType: .audio)
        var keptEmbedded = false
        for track in embeddedAudio {
            let range = try await track.load(.timeRange)
            let span = CMTimeMinimum(videoSpan, range.duration)
            guard span.isValid, span.isNumeric, span.seconds > AudioMuxAlignment.minimumUsableAudio else { continue }
            let audioComp = mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try audioComp?.insertTimeRange(CMTimeRange(start: range.start, duration: span), of: track, at: .zero)
            keptEmbedded = true
        }
        if keptEmbedded {
            if treatEmbeddedAudioAsMicrophone {
                result.includedMicrophone = true
            } else {
                result.includedSystemAudio = true
            }
        }

        var insertedSystemFile = false
        if let systemAudio {
            insertedSystemFile = try await insertExternalAudio(
                systemAudio,
                into: mix,
                videoDuration: videoSpan,
                hintedLead: systemAudioLead,
                label: "system"
            )
            if insertedSystemFile {
                result.includedSystemAudio = true
            }
        }
        var insertedMicFile = false
        if let microphone {
            insertedMicFile = try await insertExternalAudio(
                microphone,
                into: mix,
                videoDuration: videoSpan,
                hintedLead: 0,
                label: "microphone"
            )
            if insertedMicFile {
                result.includedMicrophone = true
            }
        }
        if systemAudio != nil, !insertedSystemFile {
            throw CaptureError.recordingFailed("On-screen audio was too short to mix.")
        }
        if microphone != nil, !insertedMicFile, !insertedSystemFile {
            throw CaptureError.recordingFailed("Could not mix the microphone.")
        }

        try await export(mix, to: output, videoSeconds: videoSpan.seconds)
        return result
    }

    private static func insertExternalAudio(
        _ url: URL,
        into mix: AVMutableComposition,
        videoDuration: CMTime,
        hintedLead: TimeInterval,
        label: String
    ) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard duration.isValid, duration.isNumeric else { return false }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { return false }
        let videoSecs = videoDuration.seconds
        let lead = AudioMuxAlignment.lead(
            audioDuration: duration.seconds,
            videoDuration: videoSecs,
            hintedLead: hintedLead
        )
        AudioLog.write(String(
            format: "mux %@ audio=%.3fs video=%.3fs hintedLead=%.3fs usedLead=%.3fs",
            label, duration.seconds, videoSecs, hintedLead, lead
        ))
        guard let usable = AudioMuxAlignment.usableAudioRange(
            audioDuration: duration.seconds,
            videoDuration: videoSecs,
            lead: lead
        ) else { return false }
        let start = CMTime(seconds: usable.start, preferredTimescale: 600)
        let span = CMTime(seconds: usable.duration, preferredTimescale: 600)
        guard span.isValid, span.isNumeric, span.seconds > 0 else { return false }
        let audioComp = mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        try audioComp?.insertTimeRange(CMTimeRange(start: start, duration: span), of: track, at: .zero)
        return true
    }

    private static func export(_ mix: AVMutableComposition, to output: URL, videoSeconds: TimeInterval) async throws {
        // Passthrough often fails (HEVC video + PCM tap). Re-encode so the mix always writes.
        guard let session = AVAssetExportSession(asset: mix, presetName: AVAssetExportPresetHighestQuality) else {
            throw CaptureError.recordingFailed("Could not mix on-screen audio into the recording.")
        }
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        session.outputURL = output
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = false

        let budget = max(180, videoSeconds * 4 + 60)
        let once = ResumeOnce()
        let boxed = SendBox(session)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            boxed.value.exportAsynchronously {
                once.run {
                    if boxed.value.status == .completed {
                        continuation.resume()
                    } else {
                        let message = boxed.value.error?.localizedDescription ?? "Audio mix failed."
                        continuation.resume(throwing: CaptureError.recordingFailed(message))
                    }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + budget) {
                boxed.value.cancelExport()
                once.run {
                    continuation.resume(throwing: CaptureError.recordingFailed("Audio mix timed out."))
                }
            }
        }
    }
}

private final class SendBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        body()
    }
}

/// Records the microphone to a file on macOS versions where ScreenCaptureKit
/// cannot open the microphone (before 15).
final class MicrophoneCapture {
    let url: URL
    private var recorder: AVAudioRecorder?

    init(url: URL) {
        self.url = url
    }

    func start() throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record() else {
            throw CaptureError.recordingFailed("Could not start the microphone.")
        }
        self.recorder = recorder
    }

    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }
}

/// Captures the system audio mix (browser / app sound) while screencapture records video.
final class SystemAudioTap: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "com.capturepoint.audiotap")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private var destination: URL?
    private var processTap: AnyObject?
    private(set) var framesWritten = 0

    func waitUntilLive(timeout: TimeInterval = 1.5) async {
        if #available(macOS 14.2, *), let tap = processTap as? ProcessAudioTap {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline, tap.writtenFrames < 2400 {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    func start(to url: URL) async throws {
        if #available(macOS 14.2, *) {
            let tap = ProcessAudioTap()
            try tap.start(to: url)
            processTap = tap
            destination = url
            return
        }

        destination = url
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first
        else {
            throw CaptureError.recordingFailed("No display available for on-screen audio.")
        }

        let filter: SCContentFilter
        if content.applications.isEmpty {
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else {
            filter = SCContentFilter(display: display, including: content.applications, exceptingWindows: [])
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        self.writer = writer

        let config = SCStreamConfiguration()
        config.width = 32
        config.height = 32
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // A screen output is required on some macOS versions or audio never arrives.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async -> URL? {
        if #available(macOS 14.2, *), let tap = processTap as? ProcessAudioTap {
            processTap = nil
            return tap.stop()
        }
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        let dest = destination
        let pending = SendBox((writer, input))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if let writer = pending.value.0, writer.status == .writing {
                    pending.value.1?.markAsFinished()
                    writer.finishWriting { continuation.resume() }
                    return
                }
                continuation.resume()
            }
        }
        writer = nil
        input = nil
        started = false
        guard framesWritten > 0 else {
            if let dest {
                try? FileManager.default.removeItem(at: dest)
            }
            return nil
        }
        return dest
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let writer else { return }
        if !started {
            let hint = CMSampleBufferGetFormatDescription(sampleBuffer)
            let audioInput: AVAssetWriterInput
            if let hint {
                audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            } else {
                audioInput = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: 2,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false,
                    ]
                )
            }
            audioInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(audioInput) else { return }
            writer.add(audioInput)
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            input = audioInput
            started = true
        }
        if let input, input.isReadyForMoreMediaData, input.append(sampleBuffer) {
            framesWritten += 1
        }
    }
}
