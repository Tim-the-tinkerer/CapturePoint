import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import CapturePointCore

enum AudioLog {
    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("CapturePoint", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("audio.log")
    }()

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
        NSLog("CapturePoint audio: \(message)")
    }
}

/// Records the Mac’s output mix via a Core Audio *global* process tap.
/// Chrome/Safari audio is in that mix; ScreenCaptureKit usually never sees it.
@available(macOS 14.2, *)
final class ProcessAudioTap {
    private let queue = DispatchQueue(label: "com.capturepoint.processtap", qos: .userInitiated)
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var extFile: ExtAudioFileRef?
    private var asbd = AudioStreamBasicDescription()
    private var destination: URL?
    private(set) var framesWritten = 0
    private(set) var lastError: String?

    /// Frame count read from outside the IO queue.
    var writtenFrames: Int {
        queue.sync { framesWritten }
    }

    func start(to url: URL) throws {
        destination = url
        framesWritten = 0
        lastError = nil
        AudioLog.write("ProcessAudioTap start → \(url.lastPathComponent)")

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.name = "CapturePoint On-Screen Audio"
        tapDescription.muteBehavior = .unmuted
        tapDescription.isPrivate = true
        tapDescription.isExclusive = true

        var newTap: AudioObjectID = 0
        var err = AudioHardwareCreateProcessTap(tapDescription, &newTap)
        AudioLog.write("CreateProcessTap status=\(err) tap=\(newTap)")
        guard err == noErr, newTap != 0 else {
            throw CaptureError.recordingFailed(
                "System audio tap failed (\(err)). Allow CapturePoint under System Settings → Privacy & Security → Audio Capture."
            )
        }
        tapID = newTap

        // Global tap aggregate is tap-only. Adding the output device as a
        // sub-device is what AudioCap does for *process* taps and yields
        // silence for a global tap.
        let tapUID = tapDescription.uuid.uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CapturePointGlobalAudioTap",
            kAudioAggregateDeviceUIDKey: "com.capturepoint.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID,
                ],
            ],
        ]

        var agg: AudioObjectID = 0
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg)
        AudioLog.write("CreateAggregateDevice status=\(err) agg=\(agg)")
        guard err == noErr, agg != 0 else {
            cleanup()
            throw CaptureError.recordingFailed("Could not create the system audio device (\(err)).")
        }
        aggregateID = agg

        do {
            asbd = try Self.tapFormat(tapID)
        } catch {
            cleanup()
            throw error
        }
        AudioLog.write(
            "tap format rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) flags=\(asbd.mFormatFlags)"
        )

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                cleanup()
                throw error
            }
        }
        var file: ExtAudioFileRef?
        err = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileCAFType,
            &asbd,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &file
        )
        guard err == noErr, let file else {
            cleanup()
            throw CaptureError.recordingFailed("Could not open the audio file (\(err)).")
        }
        extFile = file

        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, inInputData, _, _, _ in
            self?.write(inInputData)
        }
        guard err == noErr, ioProcID != nil else {
            ioProcID = nil
            cleanup()
            throw CaptureError.recordingFailed("Could not start system audio IO (\(err)).")
        }

        err = AudioDeviceStart(aggregateID, ioProcID)
        AudioLog.write("AudioDeviceStart status=\(err)")
        guard err == noErr else {
            cleanup()
            throw CaptureError.recordingFailed(
                "Could not start system audio (\(err)). Allow CapturePoint in System Settings → Privacy & Security → Audio Capture."
            )
        }
    }

    func stop() -> URL? {
        cleanup()
        AudioLog.write("stop frames=\(framesWritten) error=\(lastError ?? "none")")
        guard framesWritten > 0, let destination else {
            if let destination {
                try? FileManager.default.removeItem(at: destination)
            }
            return nil
        }
        return destination
    }

    /// Stops IO, closes the file, and destroys the tap. Safe to call more than once.
    private func cleanup() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        self.ioProcID = nil
        // The IO callback runs on `queue`. Wait for an in-flight write before closing the file.
        queue.sync {}
        if let extFile {
            ExtAudioFileDispose(extFile)
            self.extFile = nil
        }
        teardown()
    }

    private func write(_ listPtr: UnsafePointer<AudioBufferList>?) {
        guard let listPtr, let extFile else { return }
        let list = listPtr.pointee
        guard list.mNumberBuffers > 0 else { return }
        let bytes = list.mBuffers.mDataByteSize
        guard bytes > 0 else { return }

        let bytesPerFrame = max(1, asbd.mBytesPerFrame)
        let frames: UInt32
        if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            let bytesPerSample = max(1, asbd.mBitsPerChannel / 8)
            frames = bytes / bytesPerSample
        } else {
            frames = bytes / bytesPerFrame
        }
        guard frames > 0 else { return }
        let status = ExtAudioFileWrite(extFile, frames, listPtr)
        if status == noErr {
            framesWritten += Int(frames)
        } else {
            lastError = "ExtAudioFileWrite \(status)"
        }
    }

    private func teardown() {
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    deinit {
        if extFile != nil || tapID != 0 || aggregateID != 0 || ioProcID != nil {
            _ = stop()
        }
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard err == noErr else {
            throw CaptureError.recordingFailed("Could not read the tap format (\(err)).")
        }
        return asbd
    }
}
