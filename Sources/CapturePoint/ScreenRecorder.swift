import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit
import CapturePointCore

struct RecordingOptions {
    var mode: CaptureMode
    var destination: URL
    var includeSystemAudio: Bool
    var includeMicrophone: Bool
    var includeCursor: Bool
    var showClicks: Bool = false
    var targetWindowID: CGWindowID? = nil
}

/// Display-based ScreenCaptureKit recorder.
/// Browser windows are cropped from the display (not captured as window objects)
/// so GPU-composited pages stay visible and tab audio is in the system mix.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let writerQueue = DispatchQueue(label: "com.capturepoint.writer")
    private let writerQueueKey = DispatchSpecificKey<UInt8>()
    private let outputsLock = NSLock()
    private let startErrorLock = NSLock()
    private var outputs: [Output] = []
    /// `didStopWithError` is keyed by stream. A failure on one display must not
    /// abort the next display's start.
    private var startErrors: [ObjectIdentifier: Error] = [:]
    private var didCaptureSystemAudio = false
    private var didCaptureMicrophone = false
    private(set) var warning: String?

    override init() {
        super.init()
        writerQueue.setSpecific(key: writerQueueKey, value: 1)
    }

    private struct Target {
        var display: SCDisplay
        var width: Int
        var height: Int
        var sourceRect: CGRect?
        var cropWindowID: CGWindowID?
        var captureAudio: Bool
    }

    private final class FinishBox: @unchecked Sendable {
        let lock = NSLock()
        var urls: [URL] = []
        var failure: String?
    }

    /// Sample buffers and the writer are only touched on `writerQueue`.
    private final class Output: @unchecked Sendable {
        let destination: URL
        var cropWindowID: CGWindowID?
        var cropDisplayBounds = CGRect.zero
        var stream: SCStream?
        var writer: AVAssetWriter?
        var videoInput: AVAssetWriterInput?
        var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        var systemAudioInput: AVAssetWriterInput?
        var microphoneInput: AVAssetWriterInput?
        var sessionStarted = false
        var sessionFailed = false
        var pendingVideo: [CMSampleBuffer] = []
        var pendingAudio: [CMSampleBuffer] = []
        var pendingMic: [CMSampleBuffer] = []
        var audioFramesWritten = 0
        var microphoneFramesWritten = 0
        var videoFramesWritten = 0
        var wantSystemAudio = false
        var wantMicrophone = false

        init(destination: URL) {
            self.destination = destination
        }
    }

    var capturedOnScreenAudio: Bool {
        if didCaptureSystemAudio { return true }
        var captured = false
        onWriterQueue {
            captured = withOutputs { $0.contains { $0.audioFramesWritten > 0 } }
        }
        return captured
    }

    var capturedMicrophone: Bool {
        if didCaptureMicrophone { return true }
        var captured = false
        onWriterQueue {
            captured = withOutputs { $0.contains { $0.microphoneFramesWritten > 0 } }
        }
        return captured
    }

    /// The sample callback reads this list on `writerQueue` while start/stop
    /// run on the main actor. The lock keeps those accesses from overlapping.
    private func withOutputs<T>(_ body: (inout [Output]) -> T) -> T {
        outputsLock.lock()
        defer { outputsLock.unlock() }
        return body(&outputs)
    }

    private func takeStartError(for stream: SCStream) -> Error? {
        startErrorLock.lock()
        defer { startErrorLock.unlock() }
        return startErrors.removeValue(forKey: ObjectIdentifier(stream))
    }

    private func clearStartErrors() {
        startErrorLock.lock()
        startErrors.removeAll()
        startErrorLock.unlock()
    }

    /// Sample buffers and writers stay on `writerQueue`. Callers on that queue
    /// must not sync it again.
    private func onWriterQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: writerQueueKey) != nil {
            body()
        } else {
            writerQueue.sync(execute: body)
        }
    }

    /// Drops a stream that never became a finished movie, including the file
    /// `AVAssetWriter` created.
    private func abandon(_ output: Output) {
        onWriterQueue {
            let writer = output.writer
            output.writer = nil
            output.stream = nil
            if let writer {
                switch writer.status {
                case .unknown, .writing:
                    writer.cancelWriting()
                default:
                    break
                }
            }
        }
        try? FileManager.default.removeItem(at: output.destination)
    }

    func start(options: RecordingOptions) async throws {
        if !CaptureService.hasScreenRecordingAccess() {
            _ = CaptureService.requestScreenRecordingAccess()
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }

        var targets: [Target] = []
        switch options.mode {
        case .window:
            // Always capture the full display, then crop frames to the window.
            // Browsers (Chrome, Safari, Edge) and other GPU windows are black
            // if captured as a window object or via SCK sourceRect.
            let windowID: CGWindowID
            if let target = options.targetWindowID {
                windowID = target
            } else if let picked = await CaptureTargetPicker.pickWindowID() {
                windowID = picked
            } else {
                throw CaptureError.cancelled
            }
            guard let quartzBounds = CaptureTargetPicker.quartzBounds(windowID: windowID) else {
                throw CaptureError.recordingFailed("Could not find that window to record.")
            }
            let displayID = CaptureTargetPicker.displayID(containingQuartzRect: quartzBounds)
            guard let display = content.displays.first(where: { $0.displayID == displayID })
                    ?? content.displays.first else {
                throw CaptureError.recordingFailed("No display available to record.")
            }
            targets.append(Target(
                display: display,
                width: Self.even(display.width),
                height: Self.even(display.height),
                sourceRect: nil,
                cropWindowID: windowID,
                captureAudio: true
            ))

        case .selection:
            guard let appKitRect = await CaptureTargetPicker.pickRegion() else {
                throw CaptureError.cancelled
            }
            let displayID = CaptureTargetPicker.displayID(for: .selection)
            guard let display = content.displays.first(where: { $0.displayID == displayID })
                    ?? content.displays.first else {
                throw CaptureError.recordingFailed("No display available to record.")
            }
            let local = CaptureTargetPicker.sourceRect(appKitRect: appKitRect, displayID: display.displayID)
            let scale = CaptureTargetPicker.backingScale(displayID: display.displayID)
            targets.append(Target(
                display: display,
                width: max(2, Int(local.width * scale) & ~1),
                height: max(2, Int(local.height * scale) & ~1),
                sourceRect: local,
                cropWindowID: nil,
                captureAudio: true
            ))

        case .fullScreen, .mainDisplay:
            let ordered = Self.orderedDisplays(mode: options.mode, content: content)
            guard !ordered.isEmpty else {
                throw CaptureError.recordingFailed("No display available to record.")
            }
            for (index, display) in ordered.enumerated() {
                targets.append(Target(
                    display: display,
                    width: Self.even(display.width),
                    height: Self.even(display.height),
                    sourceRect: nil,
                    cropWindowID: nil,
                    // Sound stays on the first movie so two streams do not fight over the mix.
                    captureAudio: index == 0
                ))
            }
        }

        var warnings: [String] = []
        for (index, target) in targets.enumerated() {
            let destination = CaptureLayout.url(options.destination, displayIndex: index + 1)
            do {
                try await startStream(
                    target: target,
                    options: options,
                    destination: destination,
                    content: content
                )
            } catch {
                if index == 0 { throw error }
                warnings.append(error.localizedDescription)
            }
        }
        if !warnings.isEmpty {
            warning = "Some displays were not recorded. \(warnings.joined(separator: " "))"
        }
    }

    private static func even(_ value: Int) -> Int {
        max(2, value & ~1)
    }

    /// Full Screen records every display. The display under the pointer stays
    /// first, which is the single file older versions saved. Main Display
    /// stays one screen.
    private static func orderedDisplays(mode: CaptureMode, content: SCShareableContent) -> [SCDisplay] {
        let primaryID = CaptureTargetPicker.displayID(for: mode)
        guard let primary = content.displays.first(where: { $0.displayID == primaryID }) ?? content.displays.first else {
            return []
        }
        guard mode == .fullScreen else { return [primary] }
        return [primary] + content.displays.filter { $0.displayID != primary.displayID }
    }

    private static func filter(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let pid = ProcessInfo.processInfo.processIdentifier
        let ours = content.windows.filter { window in
            window.owningApplication?.processID == pid && window.frame.intersects(display.frame)
        }
        // The application-including filter leaves out the menu bar, Dock, and
        // desktop. Record the display itself, minus this app's own windows.
        let filter = SCContentFilter(display: display, excludingWindows: ours)
        if #available(macOS 14.2, *) {
            filter.includeMenuBar = true
        }
        return filter
    }

    private func startStream(
        target: Target,
        options: RecordingOptions,
        destination: URL,
        content: SCShareableContent
    ) async throws {
        let output = Output(destination: destination)
        output.cropWindowID = target.cropWindowID
        output.cropDisplayBounds = CGDisplayBounds(target.display.displayID)
        output.wantSystemAudio = options.includeSystemAudio && target.captureAudio
        output.wantMicrophone = options.includeMicrophone && target.captureAudio
        var committed = false
        defer {
            if !committed {
                abandon(output)
            }
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        output.writer = writer

        let config = SCStreamConfiguration()
        config.width = target.width
        config.height = target.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 8
        config.showsCursor = options.includeCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        if let sourceRect = target.sourceRect {
            config.sourceRect = sourceRect
        }
        config.capturesAudio = output.wantSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        if #available(macOS 15.0, *) {
            if output.wantMicrophone {
                config.captureMicrophone = true
            }
            if options.showClicks {
                config.showMouseClicks = true
            }
        }

        let stream = SCStream(filter: Self.filter(display: target.display, content: content), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
        if output.wantSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
        }
        if #available(macOS 15.0, *), output.wantMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: writerQueue)
        }
        output.stream = stream
        withOutputs { $0.append(output) }
        do {
            try await stream.startCapture()
        } catch {
            withOutputs { $0.removeAll { $0 === output } }
            _ = takeStartError(for: stream)
            abandon(output)
            throw error
        }
        if let startError = takeStartError(for: stream) {
            withOutputs { $0.removeAll { $0 === output } }
            try? await stream.stopCapture()
            throw startError
        }
        committed = true
    }

    func stop() async throws -> [URL] {
        let streams = withOutputs { $0.compactMap(\.stream) }
        for stream in streams {
            try? await stream.stopCapture()
        }
        onWriterQueue {
            didCaptureSystemAudio = withOutputs { $0.contains { $0.audioFramesWritten > 0 } }
            didCaptureMicrophone = withOutputs { $0.contains { $0.microphoneFramesWritten > 0 } }
        }

        let finishing = withOutputs { $0 }
        let queue = writerQueue
        let outcome: (urls: [URL], failure: String?) = await withCheckedContinuation { continuation in
            queue.async {
                let group = DispatchGroup()
                let box = FinishBox()
                for output in finishing {
                    Self.openSession(output)
                    guard let writer = output.writer else { continue }
                    if writer.status == .writing {
                        group.enter()
                        output.videoInput?.markAsFinished()
                        output.systemAudioInput?.markAsFinished()
                        output.microphoneInput?.markAsFinished()
                        let destination = output.destination
                        writer.finishWriting {
                            box.lock.lock()
                            if writer.status == .completed {
                                box.urls.append(destination)
                            } else if box.failure == nil {
                                box.failure = writer.error?.localizedDescription
                            }
                            box.lock.unlock()
                            group.leave()
                        }
                    } else if writer.status == .completed {
                        box.urls.append(output.destination)
                    } else if writer.status == .failed, box.failure == nil {
                        box.failure = writer.error?.localizedDescription
                    }
                }
                group.notify(queue: queue) {
                    continuation.resume(returning: (box.urls, box.failure))
                }
            }
        }

        let ordered = withOutputs { outputs -> [URL] in
            let urls = outputs.map(\.destination)
            outputs.removeAll()
            return urls
        }
        let kept = ordered.filter { destination in
            outcome.urls.contains { $0.path == destination.path }
        }
        let dropped = finishing.filter { output in
            !kept.contains { $0.path == output.destination.path }
        }
        for output in dropped {
            abandon(output)
        }
        clearStartErrors()
        if kept.count < ordered.count {
            let note = "Recorded \(kept.count) of \(ordered.count) displays."
            if let existing = warning, !existing.isEmpty {
                warning = "\(existing) \(note)"
            } else {
                warning = note
            }
        }
        guard !kept.isEmpty else {
            if let failure = outcome.failure {
                throw CaptureError.recordingFailed(failure)
            }
            throw CaptureError.cancelled
        }
        return kept
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let output = withOutputs { outputs in outputs.first { $0.stream === stream } }
        guard sampleBuffer.isValid, let output else { return }
        if output.sessionFailed { return }

        if !output.sessionStarted {
            switch type {
            case .screen:
                if output.pendingVideo.count < 45 {
                    output.pendingVideo.append(sampleBuffer)
                }
            case .audio:
                if output.pendingAudio.count < 45 {
                    output.pendingAudio.append(sampleBuffer)
                }
            default:
                if #available(macOS 15.0, *), type == .microphone, output.pendingMic.count < 45 {
                    output.pendingMic.append(sampleBuffer)
                }
            }
            Self.openSession(output)
            return
        }

        Self.appendLive(sampleBuffer, type: type, output: output)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        startErrorLock.lock()
        let key = ObjectIdentifier(stream)
        if startErrors[key] == nil {
            startErrors[key] = error
        }
        startErrorLock.unlock()
    }

    private static func openSession(_ output: Output) {
        guard !output.sessionStarted, !output.sessionFailed else { return }
        guard let writer = output.writer, writer.status == .unknown else { return }
        guard let firstVideo = output.pendingVideo.first,
              let rawBuffer = CMSampleBufferGetImageBuffer(firstVideo)
        else { return }
        let pixelBuffer = Self.croppedBuffer(
            rawBuffer,
            windowID: output.cropWindowID,
            displayBounds: output.cropDisplayBounds
        ) ?? rawBuffer

        let width = max(2, CVPixelBufferGetWidth(pixelBuffer) & ~1)
        let height = max(2, CVPixelBufferGetHeight(pixelBuffer) & ~1)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * 4),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            output.sessionFailed = true
            return
        }
        writer.add(videoInput)
        output.videoInput = videoInput
        output.videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        if output.wantSystemAudio {
            let hint = output.pendingAudio.first.flatMap { CMSampleBufferGetFormatDescription($0) }
            let audioInput = Self.makeAudioInput(formatHint: hint)
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                output.systemAudioInput = audioInput
            }
        }
        if output.wantMicrophone {
            let hint = output.pendingMic.first.flatMap { CMSampleBufferGetFormatDescription($0) }
            let micInput = Self.makeAudioInput(formatHint: hint)
            if writer.canAdd(micInput) {
                writer.add(micInput)
                output.microphoneInput = micInput
            }
        }

        guard writer.startWriting() else {
            output.sessionFailed = true
            output.pendingVideo = []
            output.pendingAudio = []
            output.pendingMic = []
            return
        }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(firstVideo))
        output.sessionStarted = true

        let videos = output.pendingVideo
        let audios = output.pendingAudio
        let mics = output.pendingMic
        output.pendingVideo = []
        output.pendingAudio = []
        output.pendingMic = []
        for sample in videos { appendLive(sample, type: .screen, output: output) }
        for sample in audios { appendLive(sample, type: .audio, output: output) }
        if #available(macOS 15.0, *) {
            for sample in mics { appendLive(sample, type: .microphone, output: output) }
        }
    }

    private static func appendLive(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType, output: Output) {
        switch type {
        case .screen:
            guard let adaptor = output.videoAdaptor,
                  adaptor.assetWriterInput.isReadyForMoreMediaData,
                  let raw = CMSampleBufferGetImageBuffer(sampleBuffer)
            else { return }
            let pixelBuffer = Self.croppedBuffer(
                raw,
                windowID: output.cropWindowID,
                displayBounds: output.cropDisplayBounds
            ) ?? raw
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if adaptor.append(pixelBuffer, withPresentationTime: time) {
                output.videoFramesWritten += 1
            }
        case .audio:
            guard let input = output.systemAudioInput, input.isReadyForMoreMediaData else { return }
            if input.append(sampleBuffer) {
                output.audioFramesWritten += 1
            }
        default:
            if #available(macOS 15.0, *), type == .microphone {
                guard let input = output.microphoneInput, input.isReadyForMoreMediaData else { return }
                if input.append(sampleBuffer) {
                    output.microphoneFramesWritten += 1
                }
            }
        }
    }

    /// Crops a full-display frame to the live window bounds (points → buffer pixels).
    private static func croppedBuffer(
        _ source: CVPixelBuffer,
        windowID: CGWindowID?,
        displayBounds: CGRect
    ) -> CVPixelBuffer? {
        guard let windowID, displayBounds.width > 0, displayBounds.height > 0 else { return nil }
        guard let win = CaptureTargetPicker.quartzBounds(windowID: windowID) else { return nil }

        let bufW = CVPixelBufferGetWidth(source)
        let bufH = CVPixelBufferGetHeight(source)
        let scaleX = CGFloat(bufW) / displayBounds.width
        let scaleY = CGFloat(bufH) / displayBounds.height

        var x = Int(((win.minX - displayBounds.minX) * scaleX).rounded(.down))
        var y = Int(((win.minY - displayBounds.minY) * scaleY).rounded(.down))
        var w = Int((win.width * scaleX).rounded(.up)) & ~1
        var h = Int((win.height * scaleY).rounded(.up)) & ~1
        x = max(0, min(x, bufW - 2))
        y = max(0, min(y, bufH - 2))
        w = max(2, min(w, bufW - x)) & ~1
        h = max(2, min(h, bufH - y)) & ~1
        guard w >= 2, h >= 2 else { return nil }

        var dest: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            w,
            h,
            CVPixelBufferGetPixelFormatType(source),
            nil,
            &dest
        )
        guard status == kCVReturnSuccess, let dest else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(dest, [])
        }
        guard
            let srcBase = CVPixelBufferGetBaseAddress(source),
            let dstBase = CVPixelBufferGetBaseAddress(dest)
        else { return nil }

        let srcRow = CVPixelBufferGetBytesPerRow(source)
        let dstRow = CVPixelBufferGetBytesPerRow(dest)
        // Row bytes are often padded, so width does not divide the row evenly.
        let bytesPerPixel: Int
        switch CVPixelBufferGetPixelFormatType(source) {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB,
             kCVPixelFormatType_32ABGR, kCVPixelFormatType_32RGBA:
            bytesPerPixel = 4
        default:
            bytesPerPixel = max(1, srcRow / max(bufW, 1))
        }
        for row in 0..<h {
            let s = srcBase.advanced(by: (y + row) * srcRow + x * bytesPerPixel)
            let d = dstBase.advanced(by: row * dstRow)
            memcpy(d, s, min(w * bytesPerPixel, dstRow))
        }
        return dest
    }

    private static func makeAudioInput(formatHint: CMFormatDescription?) -> AVAssetWriterInput {
        if let formatHint {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: formatHint
            )
            input.expectsMediaDataInRealTime = true
            return input
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return input
    }
}
