import AVFoundation
import AppKit
import Combine
import Foundation
import CapturePointCore
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var statusMessage = "Ready"
    @Published var isCapturing = false
    @Published var isRecording = false
    @Published var recordingElapsed: TimeInterval = 0
    @Published var lastError: String?
    @Published var selectedShotID: ShotRecord.ID?
    @Published var permissions = PermissionSnapshot.checking

    let settings: SettingsStore
    let history: HistoryStore

    private let countdown = CountdownHUD()
    private let recordingHUD = RecordingHUD()
    private var cancellables = Set<AnyCancellable>()
    private var recorder: ScreenRecorder?
    private var recordingProcess: Process?
    private var audioTap: SystemAudioTap?
    private var audioTempURL: URL?
    private var recordingTempURL: URL?
    private var recordLimitTask: Task<Void, Never>?
    private var recordingMode: CaptureMode?
    private var recordingStartedAt: Date?
    private var recordingTick: Timer?
    @Published private(set) var isFinishingRecording = false
    /// True from the click until the recording is actually running, including the countdown.
    @Published private(set) var isArmingRecording = false
    private var finishTask: Task<Void, Never>?
    private var isTerminating = false
    private var microphoneDenied = false
    private var microphoneCapture: MicrophoneCapture?
    private var hiddenMainWindow: NSWindow?
    private var audioCaptureStartedAt: Date?
    private var videoCaptureStartedAt: Date?
    private var videoStartWatchTask: Task<Void, Never>?

    init(settings: SettingsStore? = nil, history: HistoryStore? = nil) {
        self.settings = settings ?? SettingsStore()
        self.history = history ?? HistoryStore()
        selectedShotID = self.history.shots.first?.id
        refreshPermissions()
        if let warning = self.history.loadWarning {
            lastError = warning
            statusMessage = warning
        }

        self.settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        self.history.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var selectedShot: ShotRecord? {
        if let selectedShotID, let match = history.shots.first(where: { $0.id == selectedShotID }) {
            return match
        }
        return history.shots.first
    }

    var folderDisplay: String {
        PathDisplay.tildePath(settings.saveFolder)
    }

    var canCapture: Bool {
        !isCapturing && !isRecording && !isFinishingRecording && !isArmingRecording
    }

    var canRecord: Bool {
        canCapture
    }

    func capture(_ mode: CaptureMode) {
        guard canCapture else { return }
        isCapturing = true
        lastError = nil
        statusMessage = status(for: mode)

        Task { @MainActor in
            defer { isCapturing = false }
            do {
                try await performCapture(mode)
            } catch let error as CaptureError {
                if case .cancelled = error {
                    statusMessage = "Capture cancelled"
                } else if case .saveCancelled = error {
                    statusMessage = error.localizedDescription
                } else {
                    lastError = error.localizedDescription
                    statusMessage = error.localizedDescription
                }
            } catch {
                lastError = error.localizedDescription
                statusMessage = error.localizedDescription
            }
        }
    }

    func chooseSaveFolder() {
        do {
            try settings.chooseSaveFolder()
            statusMessage = "Save folder: \(folderDisplay)"
        } catch {
            report(error)
        }
    }

    func applyPreset(_ preset: FolderPreset) {
        do {
            try settings.applyPreset(preset)
            statusMessage = "Save folder: \(folderDisplay)"
        } catch {
            report(error)
        }
    }

    func useSaveFolder(_ url: URL) {
        do {
            try settings.setSaveFolder(url)
            statusMessage = "Save folder: \(folderDisplay)"
        } catch {
            report(error)
        }
    }

    func openSaveFolder() {
        do {
            try settings.openSaveFolder()
        } catch {
            report(error)
        }
    }

    func reveal(_ record: ShotRecord) {
        let url = record.url
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            statusMessage = "File is no longer at \(url.lastPathComponent)"
            try? history.pruneMissing()
        }
    }

    func open(_ record: ShotRecord) {
        let url = record.url
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            statusMessage = "File is no longer at \(url.lastPathComponent)"
            try? history.pruneMissing()
        }
    }

    func copy(_ record: ShotRecord) {
        let url = record.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "File is no longer at \(url.lastPathComponent)"
            try? history.pruneMissing()
            return
        }
        if record.isVideo {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
            statusMessage = "Copied \(record.filename)"
            return
        }
        if CaptureService.copyImageFileToClipboard(url) {
            statusMessage = "Copied \(record.filename)"
        } else {
            statusMessage = "Could not copy \(url.lastPathComponent)"
        }
    }

    func trash(_ record: ShotRecord) {
        let name = record.filename
        do {
            try history.trash(record)
            if selectedShotID == record.id {
                selectedShotID = history.shots.first?.id
            }
            statusMessage = "Moved \(name) to Trash"
        } catch {
            report(error)
        }
    }

    func refreshPermissions() {
        permissions = PermissionChecker.snapshot(
            wantsOnScreenAudio: settings.recordSystemAudio,
            wantsMicrophone: settings.recordMicrophone
        )
    }

    func requestPermission(_ kind: AppPermission) {
        switch kind {
        case .screenRecording:
            requestScreenPermission()
        case .audioCapture:
            requestAudioCapturePermission()
        case .microphone:
            requestMicrophonePermission()
        }
    }

    func requestScreenPermission() {
        refreshPermissions()
        if CaptureService.hasScreenRecordingAccess() {
            statusMessage = "Screen Recording permission is already granted"
            PermissionChecker.openSettings(for: .screenRecording)
            return
        }
        _ = CaptureService.requestScreenRecordingAccess()
        refreshPermissions()
        if CaptureService.hasScreenRecordingAccess() {
            statusMessage = "Screen Recording permission granted"
        } else {
            statusMessage = "Grant Screen Recording in System Settings → Privacy & Security → Screen Recording, then capture again"
            PermissionChecker.openSettings(for: .screenRecording)
        }
    }

    func requestAudioCapturePermission() {
        refreshPermissions()
        if !PermissionPolicy.supportsOnScreenAudio(ProcessInfo.processInfo.operatingSystemVersion) {
            statusMessage = "On-screen audio requires macOS 14.2 or later"
            return
        }
        statusMessage = "Grant Audio Capture in System Settings → Privacy & Security if macOS asks when you record"
        PermissionChecker.openSettings(for: .audioCapture)
    }

    func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshPermissions()
                if granted {
                    self.statusMessage = "Microphone permission granted"
                } else {
                    self.statusMessage = "Grant Microphone in System Settings → Privacy & Security → Microphone"
                    PermissionChecker.openSettings(for: .microphone)
                }
            }
        }
    }

    // MARK: - Recording

    func startRecording(_ mode: CaptureMode) {
        guard canRecord else { return }
        isArmingRecording = true
        lastError = nil
        statusMessage = recordStatus(for: mode)

        Task { @MainActor in
            defer { isArmingRecording = false }
            do {
                try await beginRecording(mode)
            } catch let error as CaptureError {
                if case .cancelled = error {
                    statusMessage = "Recording cancelled"
                } else {
                    lastError = error.localizedDescription
                    statusMessage = error.localizedDescription
                }
            } catch {
                lastError = error.localizedDescription
                statusMessage = error.localizedDescription
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        statusMessage = "Stopping recording…"
        Task { @MainActor in
            await finishRecording()
        }
    }

    func stopRecordingIfNeeded() {
        guard isRecording else { return }
        Task { @MainActor in
            await finishRecording()
        }
    }

    /// Sets the quit flag before the process winds down, including during a countdown.
    func beginTermination() {
        isTerminating = true
    }

    /// Quit waits until an in-progress recording is on disk.
    /// A countdown or a still capture that has not finished is cancelled first,
    /// so the app does not exit while `screencapture` or a new recording is starting.
    func finishForTermination() async {
        isTerminating = true
        while isArmingRecording || isCapturing {
            CaptureService.cancelActive()
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if isRecording || isFinishingRecording {
            await finishRecording()
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording(.fullScreen)
        }
    }

    private func beginRecording(_ mode: CaptureMode) async throws {
        if !CaptureService.hasScreenRecordingAccess() {
            _ = CaptureService.requestScreenRecordingAccess()
        }
        try FileDestination.ensureFolder(settings.saveFolder)

        let delay = max(0, settings.delaySeconds)
        if delay > 0 {
            statusMessage = "Recording starts in \(delay)…"
            await countdown.run(seconds: delay) { self.isTerminating }
        }
        if isTerminating {
            statusMessage = "Recording cancelled"
            return
        }

        let mainWindow = NSApp.windows.first { $0.title == "CapturePoint" && $0.isVisible }
        if settings.hideApp {
            mainWindow?.orderOut(nil)
            hiddenMainWindow = mainWindow
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapturePoint-\(UUID().uuidString).mov")

        // Window/selection: system picker for video + process tap for audio.
        // Full screen uses ScreenCaptureKit (picture and audio share one clock).
        let useSystemPicker = (mode == .window || mode == .selection)
        audioCaptureStartedAt = nil
        videoCaptureStartedAt = nil
        videoStartWatchTask?.cancel()
        videoStartWatchTask = nil
        microphoneDenied = false

        if settings.recordMicrophone {
            let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            if !granted {
                microphoneDenied = true
                let note = "Microphone permission was denied. Recording continues without it."
                lastError = note
                statusMessage = note
            }
        }
        if isTerminating {
            restoreRecordingUI()
            statusMessage = "Recording cancelled"
            return
        }

        if settings.recordSystemAudio, useSystemPicker {
            let tap = SystemAudioTap()
            let audioURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("CapturePoint-audio-\(UUID().uuidString).caf")
            do {
                try await tap.start(to: audioURL)
                audioTap = tap
                audioTempURL = audioURL
                audioCaptureStartedAt = Date()
                PermissionChecker.rememberAudioCapture(granted: true)
                refreshPermissions()
                await tap.waitUntilLive()
            } catch {
                audioTap = nil
                audioTempURL = nil
                try? FileManager.default.removeItem(at: audioURL)
                PermissionChecker.rememberAudioCapture(granted: false)
                refreshPermissions()
                lastError = error.localizedDescription
                statusMessage = error.localizedDescription
            }
        }
        if isTerminating {
            await discardPreparedAudio()
            restoreRecordingUI()
            statusMessage = "Recording cancelled"
            return
        }

        let allowMic = settings.recordMicrophone && !microphoneDenied
        if useSystemPicker {
            do {
                let process = try RecordingService.start(
                    mode: mode,
                    destination: tempURL,
                    microphone: allowMic,
                    playSound: settings.playSound,
                    includeCursor: settings.includeCursor,
                    showClicks: settings.showClicks,
                    timeLimitSeconds: settings.recordLimitSeconds,
                    onExit: { [weak self] in
                        Task { @MainActor in
                            await self?.finishRecording()
                        }
                    }
                )
                recordingProcess = process
                let watchURL = tempURL
                videoStartWatchTask = Task { [weak self] in
                    let started = await RecordingService.waitForFileData(watchURL)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self, self.isRecording else { return }
                        if let started {
                            self.videoCaptureStartedAt = started
                            self.recordingStartedAt = started
                            self.recordingElapsed = 0
                            self.recordingHUD.updateElapsed(0)
                            AudioLog.write("video file began at \(started)")
                        } else {
                            AudioLog.write("video file watch timed out; mux will use duration lead")
                        }
                    }
                }
            } catch {
                await discardPreparedAudio()
                restoreRecordingUI()
                throw error
            }
        } else {
            // ScreenCaptureKit can open the microphone only on macOS 15+.
            // Earlier systems record it to a sidecar file and mix it in later.
            var captureMicInStream = false
            if allowMic {
                if #available(macOS 15.0, *) {
                    captureMicInStream = true
                } else {
                    let micURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("CapturePoint-mic-\(UUID().uuidString).m4a")
                    let mic = MicrophoneCapture(url: micURL)
                    do {
                        try mic.start()
                    } catch {
                        try? FileManager.default.removeItem(at: micURL)
                        await discardPreparedAudio()
                        restoreRecordingUI()
                        throw error
                    }
                    microphoneCapture = mic
                }
            }
            let recorder = ScreenRecorder()
            do {
                try await recorder.start(
                    options: RecordingOptions(
                        mode: mode,
                        destination: tempURL,
                        includeSystemAudio: settings.recordSystemAudio,
                        includeMicrophone: captureMicInStream,
                        includeCursor: settings.includeCursor,
                        showClicks: settings.showClicks
                    )
                )
            } catch {
                await discardPreparedAudio()
                restoreRecordingUI()
                throw error
            }
            self.recorder = recorder
            videoCaptureStartedAt = Date()
        }

        recordingTempURL = tempURL
        recordingMode = mode
        recordingStartedAt = Date()
        recordingElapsed = 0
        if isTerminating {
            restoreRecordingUI()
            await finishRecording()
            return
        }
        isRecording = true
        statusMessage = recordStatus(for: mode)
        startRecordingTick()
        recordingHUD.show { [weak self] in
            self?.stopRecording()
        }

        // screencapture -V starts when the user clicks. The in-app timer would
        // count the time spent in the picker, so it is only used for ScreenCaptureKit.
        let limit = settings.recordLimitSeconds
        if limit > 0, !useSystemPicker {
            recordLimitTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(limit) * 1_000_000_000)
                guard let self, !Task.isCancelled, self.isRecording else { return }
                self.statusMessage = "Stopping recording…"
                await self.finishRecording()
            }
        }
    }

    private func finishRecording() async {
        if let finishTask {
            await finishTask.value
            return
        }
        let task = Task { @MainActor in
            await self.finishRecordingBody()
        }
        finishTask = task
        await task.value
        finishTask = nil
    }

    private func finishRecordingBody() async {
        let idle = !isRecording
            && recordingProcess == nil
            && recorder == nil
            && audioTap == nil
            && recordingTempURL == nil
            && microphoneCapture == nil
        guard !idle else { return }

        isFinishingRecording = true
        defer {
            isFinishingRecording = false
            recordingMode = nil
            recordingStartedAt = nil
            recordingElapsed = 0
            audioCaptureStartedAt = nil
            videoCaptureStartedAt = nil
            microphoneDenied = false
            microphoneCapture = nil
        }

        recordLimitTask?.cancel()
        recordLimitTask = nil
        videoStartWatchTask?.cancel()
        videoStartWatchTask = nil
        stopRecordingTick()
        recordingHUD.close()

        let recorder = self.recorder
        let process = recordingProcess
        let tap = audioTap
        let tempURL = recordingTempURL
        let audioURL = audioTempURL
        let micCapture = microphoneCapture
        let startedAt = recordingStartedAt
        let hudElapsed = recordingElapsed
        let micWasDenied = microphoneDenied
        self.recorder = nil
        recordingProcess = nil
        audioTap = nil
        recordingTempURL = nil
        audioTempURL = nil
        microphoneCapture = nil
        isRecording = false

        if let process, process.isRunning {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    RecordingService.interrupt(process)
                    RecordingService.waitUntilExit(process)
                    continuation.resume()
                }
            }
        }

        var files: [URL] = []
        if let recorder {
            do {
                files = try await recorder.stop()
            } catch let error as CaptureError {
                await discardAudio(tap: tap, audioURL: audioURL, microphone: micCapture)
                restoreRecordingUI()
                if case .cancelled = error {
                    statusMessage = "Recording cancelled"
                } else {
                    lastError = error.localizedDescription
                    statusMessage = error.localizedDescription
                }
                return
            } catch {
                await discardAudio(tap: tap, audioURL: audioURL, microphone: micCapture)
                restoreRecordingUI()
                lastError = error.localizedDescription
                statusMessage = error.localizedDescription
                return
            }
        } else if let tempURL {
            files = [tempURL]
        }

        statusMessage = "Saving recording…"
        var audioNote: String?
        var muxResult: RecordingService.MuxResult?
        let capturedSystem = await tap?.stop()
        if tap != nil {
            if let capturedSystem {
                AudioLog.write("tap produced file \(capturedSystem.lastPathComponent)")
            } else {
                audioNote = "no on-screen audio samples (allow Audio Capture for CapturePoint)"
                AudioLog.write("tap returned no file (0 frames or stop failed)")
                if let audioURL {
                    try? FileManager.default.removeItem(at: audioURL)
                }
            }
        }
        _ = audioURL
        let capturedMic = micCapture?.stop()

        if let primary = files.first, capturedSystem != nil || capturedMic != nil {
            let mixed = FileManager.default.temporaryDirectory
                .appendingPathComponent("CapturePoint-mixed-\(UUID().uuidString).mov")
            let lead: TimeInterval
            if let audioT0 = audioCaptureStartedAt, let videoT0 = videoCaptureStartedAt {
                lead = AudioMuxAlignment.hintedLead(audioStarted: audioT0, videoStarted: videoT0)
            } else {
                lead = 0
            }
            AudioLog.write(String(format: "mux audioLead=%.3fs", lead))
            let treatEmbedded = process != nil && settings.recordMicrophone && !micWasDenied
            do {
                muxResult = try await RecordingService.mux(
                    video: primary,
                    systemAudio: capturedSystem,
                    systemAudioLead: lead,
                    microphone: capturedMic,
                    to: mixed,
                    treatEmbeddedAudioAsMicrophone: treatEmbedded
                )
                try? FileManager.default.removeItem(at: primary)
                if let capturedSystem { try? FileManager.default.removeItem(at: capturedSystem) }
                if let capturedMic { try? FileManager.default.removeItem(at: capturedMic) }
                files[0] = mixed
                AudioLog.write("mux ok")
            } catch {
                audioNote = "audio mix failed: \(error.localizedDescription)"
                AudioLog.write("mux failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: mixed)
                if let capturedSystem { try? FileManager.default.removeItem(at: capturedSystem) }
                if let capturedMic { try? FileManager.default.removeItem(at: capturedMic) }
            }
        } else {
            if let capturedSystem { try? FileManager.default.removeItem(at: capturedSystem) }
            if let capturedMic { try? FileManager.default.removeItem(at: capturedMic) }
        }

        restoreRecordingUI()

        let existing: Set<String>
        do {
            existing = try FilenameGenerator.filenames(in: settings.saveFolder)
        } catch {
            let keptNote = files.first.map { " Recording is still at \($0.path)." } ?? ""
            lastError = error.localizedDescription
            statusMessage = error.localizedDescription + keptNote
            return
        }
        let suggested = CaptureFinalizer.suggestedName(
            kind: .recording,
            existingFilenames: existing,
            now: startedAt ?? Date()
        )

        let saved: SavedCapture
        do {
            saved = try saveCaptured(files: files, kind: .recording, suggestedPrimary: suggested)
        } catch let error as CaptureError {
            if case .saveCancelled = error {
                statusMessage = error.localizedDescription
            } else if case .cancelled = error {
                statusMessage = "Recording cancelled"
            } else {
                lastError = error.localizedDescription
                statusMessage = error.localizedDescription
            }
            return
        } catch {
            lastError = error.localizedDescription
            statusMessage = error.localizedDescription
            return
        }

        let elapsed: TimeInterval
        if let primary = saved.urls.first, let seconds = await mediaDuration(of: primary) {
            elapsed = seconds
        } else {
            elapsed = hudElapsed
        }
        let hasSystem: Bool
        let hasMic: Bool
        if let muxResult {
            hasSystem = muxResult.includedSystemAudio
            hasMic = muxResult.includedMicrophone
        } else {
            hasSystem = recorder?.capturedOnScreenAudio == true
            if recorder?.capturedMicrophone == true {
                hasMic = true
            } else {
                hasMic = process != nil && settings.recordMicrophone && !micWasDenied
            }
        }
        if settings.recordSystemAudio, !hasSystem, audioNote == nil {
            audioNote = "no on-screen audio samples (allow Audio Capture for CapturePoint)"
        }
        let sound = soundDescription(hasSystem: hasSystem, hasMic: hasMic, audioNote: audioNote)
        var status = recordingSavedStatus(files: saved.urls, elapsed: elapsed, sound: sound)
        var extras: [String] = []
        if let audioNote, sound != audioNote, audioNote.hasPrefix("audio mix failed") || (hasMic && !hasSystem) {
            extras.append(audioNote)
        }
        if let note = recorder?.warning, !note.isEmpty {
            extras.append(note)
        }
        if let warning = saved.warning {
            lastError = warning
            if saved.urls.count == 1, warning.hasPrefix("Saved ") {
                status = warning
            } else {
                extras.append(warning)
            }
        }
        if !extras.isEmpty {
            status += " " + extras.joined(separator: " ")
        }
        statusMessage = status
    }

    private func discardPreparedAudio() async {
        let tap = audioTap
        let audioURL = audioTempURL
        let microphone = microphoneCapture
        audioTap = nil
        audioTempURL = nil
        microphoneCapture = nil
        await discardAudio(tap: tap, audioURL: audioURL, microphone: microphone)
    }

    private func discardAudio(tap: SystemAudioTap?, audioURL: URL?, microphone: MicrophoneCapture?) async {
        if let tap {
            _ = await tap.stop()
        }
        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        if let microphone, let url = microphone.stop() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func mediaDuration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              duration.isValid,
              duration.isNumeric,
              duration.seconds > 0
        else { return nil }
        return duration.seconds
    }

    private func soundDescription(hasSystem: Bool, hasMic: Bool, audioNote: String?) -> String {
        if hasSystem, hasMic { return "with on-screen audio and microphone" }
        if hasSystem { return "with on-screen audio" }
        if hasMic { return "with microphone" }
        if let audioNote { return audioNote }
        return "picture only"
    }

    private func recordingSavedStatus(files: [URL], elapsed: TimeInterval, sound: String) -> String {
        let folder = PathDisplay.tildePath(FileDestination.parentDirectory(of: files[0]) ?? settings.saveFolder)
        let clock = PathDisplay.clock(elapsed)
        if files.count == 1 {
            return "Saved \(files[0].lastPathComponent) (\(clock), \(sound)) → \(folder)"
        }
        let detail = sound.hasPrefix("with ") ? "\(sound) in the first file" : sound
        return "Saved \(files.count) recordings (\(clock), \(detail)) → \(folder)"
    }

    private func startRecordingTick() {
        recordingTick?.invalidate()
        recordingTick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let start = self.recordingStartedAt else { return }
                self.recordingElapsed = Date().timeIntervalSince(start)
                self.recordingHUD.updateElapsed(self.recordingElapsed)
                if let mode = self.recordingMode {
                    self.statusMessage = "\(self.recordStatus(for: mode)) \(PathDisplay.clock(self.recordingElapsed))"
                }
            }
        }
        if let tick = recordingTick {
            RunLoop.main.add(tick, forMode: .common)
        }
    }

    private func stopRecordingTick() {
        recordingTick?.invalidate()
        recordingTick = nil
    }

    private func restoreRecordingUI() {
        if let window = hiddenMainWindow {
            window.makeKeyAndOrderFront(nil)
            hiddenMainWindow = nil
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func recordStatus(for mode: CaptureMode) -> String {
        switch mode {
        case .selection: return "Recording selection…"
        case .window: return "Recording window…"
        case .fullScreen: return "Recording…"
        case .mainDisplay: return "Recording main display…"
        }
    }

    // MARK: - Capture pipeline

    private func performCapture(_ mode: CaptureMode) async throws {
        if !CaptureService.hasScreenRecordingAccess() {
            _ = CaptureService.requestScreenRecordingAccess()
        }

        try FileDestination.ensureFolder(settings.saveFolder)

        let delay = max(0, settings.delaySeconds)
        if delay > 0 {
            statusMessage = "Starting in \(delay)…"
            await countdown.run(seconds: delay) { self.isTerminating }
        }
        if isTerminating {
            statusMessage = "Capture cancelled"
            return
        }

        let mainWindow = NSApp.windows.first { $0.title == "CapturePoint" && $0.isVisible }
        var didHideApp = false
        if settings.hideApp {
            mainWindow?.orderOut(nil)
            NSApp.hide(nil)
            didHideApp = true
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        if isTerminating {
            restoreApp(window: mainWindow, didHide: didHideApp)
            statusMessage = "Capture cancelled"
            return
        }

        let existing = try FilenameGenerator.filenames(in: settings.saveFolder)
        let suggested = CaptureFinalizer.suggestedName(
            kind: .still,
            existingFilenames: existing,
            format: settings.format
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapturePoint-\(UUID().uuidString).\(settings.format.fileExtension)")

        let format = settings.format
        let includeCursor = settings.includeCursor
        let playSound = settings.playSound
        let copyToClipboard = settings.copyToClipboard

        let result: StillCaptureResult
        do {
            result = try await runCapture(
                mode: mode,
                destination: tempURL,
                format: format,
                includeCursor: includeCursor,
                playSound: playSound,
                copyToClipboard: copyToClipboard
            )
        } catch {
            restoreApp(window: mainWindow, didHide: didHideApp)
            throw error
        }

        restoreApp(window: mainWindow, didHide: didHideApp)

        let saved = try saveCaptured(files: result.files, kind: .still, suggestedPrimary: suggested)
        let folder = PathDisplay.tildePath(FileDestination.parentDirectory(of: saved.urls[0]) ?? settings.saveFolder)
        var status: String
        if saved.urls.count == 1 {
            status = "Saved \(saved.urls[0].lastPathComponent) → \(folder)"
        } else {
            status = "Saved \(saved.urls.count) screenshots → \(folder)"
        }
        if let warning = saved.warning {
            lastError = warning
            if saved.urls.count == 1, warning.hasPrefix("Saved ") {
                status = warning
            } else {
                status += " \(warning)"
            }
        }
        if let warning = result.warning, !warning.isEmpty {
            status += " \(warning)"
        }
        statusMessage = status
    }

    private func runCapture(
        mode: CaptureMode,
        destination: URL,
        format: ImageFormat,
        includeCursor: Bool,
        playSound: Bool,
        copyToClipboard: Bool,
    ) async throws -> StillCaptureResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StillCaptureResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try CaptureService.run(
                        mode: mode,
                        destination: destination,
                        format: format,
                        includeCursor: includeCursor,
                        playSound: playSound,
                        copyToClipboard: copyToClipboard
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private struct SavedCapture {
        var urls: [URL]
        var warning: String?
    }

    /// Moves keepable temp files into the save folder. The first file keeps
    /// `suggestedPrimary`. Later files are that name plus " Display N".
    private func saveCaptured(
        files: [URL],
        kind: CapturedMediaKind,
        suggestedPrimary: String
    ) throws -> SavedCapture {
        var ready: [URL] = []
        for file in files {
            switch CaptureFinalizer.outcome(temporaryFile: file, kind: kind) {
            case .cancelled:
                try? FileManager.default.removeItem(at: file)
            case .ready(let url, _):
                ready.append(url)
            }
        }
        guard !ready.isEmpty else { throw CaptureError.cancelled }

        var saved: [URL] = []
        var warnings: [String] = []
        var primaryID: ShotRecord.ID?
        var moveError: Error?

        func commit(_ file: URL, to dest: URL, primary: Bool) {
            do {
                try FileDestination.moveReplacing(from: file, to: dest)
            } catch {
                moveError = error
                warnings.append(error.localizedDescription)
                return
            }
            saved.append(dest)
            do {
                try history.add(url: dest)
                if primary, let id = history.shots.first(where: { $0.path == dest.path })?.id {
                    primaryID = id
                }
            } catch {
                warnings.append("Saved \(dest.lastPathComponent) but Recent list failed: \(error.localizedDescription)")
            }
        }

        switch settings.saveBehavior {
        case .folder:
            var existing = try FilenameGenerator.filenames(in: settings.saveFolder)
            for (index, file) in ready.enumerated() {
                let wanted = CaptureLayout.filename(primary: suggestedPrimary, displayIndex: index + 1)
                let name: String
                if index == 0 {
                    name = wanted
                    existing.insert(name)
                } else {
                    name = uniqueFilename(wanted, existing: &existing)
                }
                commit(file, to: settings.saveFolder.appendingPathComponent(name), primary: index == 0)
            }
            if !saved.isEmpty {
                settings.rememberFolder(settings.saveFolder)
            }
        case .askEachTime:
            let message = kind == .recording
                ? (ready.count > 1
                    ? "Choose where to save this recording. Each other display is saved beside it."
                    : "Choose where to save this recording")
                : (ready.count > 1
                    ? "Choose where to save this screenshot. Each other display is saved beside it."
                    : "Choose where to save this screenshot")
            guard let picked = CaptureService.presentSavePanel(
                defaultDirectory: settings.saveFolder,
                suggestedName: suggestedPrimary,
                message: message
            ) else {
                for file in ready { try? FileManager.default.removeItem(at: file) }
                throw CaptureError.saveCancelled
            }
            let parent = FileDestination.parentDirectory(of: picked) ?? settings.saveFolder
            var existing = (try? FilenameGenerator.filenames(in: parent)) ?? []
            existing.insert(picked.lastPathComponent)
            commit(ready[0], to: picked, primary: true)
            for (offset, file) in ready.dropFirst().enumerated() {
                let wanted = CaptureLayout.filename(primary: picked.lastPathComponent, displayIndex: offset + 2)
                let name = uniqueFilename(wanted, existing: &existing)
                commit(file, to: parent.appendingPathComponent(name), primary: false)
            }
            if !saved.isEmpty {
                do {
                    try settings.setSaveFolder(parent)
                } catch {
                    warnings.append(error.localizedDescription)
                }
            }
        }

        guard !saved.isEmpty else {
            throw moveError ?? CaptureError.cancelled
        }
        if let primaryID {
            selectedShotID = primaryID
        } else if let match = history.shots.first(where: { shot in saved.contains { $0.path == shot.path } }) {
            selectedShotID = match.id
        }
        let warning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        return SavedCapture(urls: saved, warning: warning)
    }

    private func uniqueFilename(_ name: String, existing: inout Set<String>) -> String {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let unique = FilenameGenerator.uniqueName(base: base, ext: ext.isEmpty ? "dat" : ext, existing: existing)
        existing.insert(unique)
        return unique
    }

    private func restoreApp(window: NSWindow?, didHide: Bool) {
        if didHide {
            NSApp.unhide(nil)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        statusMessage = error.localizedDescription
    }

    private func status(for mode: CaptureMode) -> String {
        switch mode {
        case .selection: return "Drag to select an area…"
        case .window: return "Click a window…"
        case .fullScreen: return "Capturing all displays…"
        case .mainDisplay: return "Capturing the main display…"
        }
    }
}
