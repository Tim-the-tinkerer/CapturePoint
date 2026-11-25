import AVFoundation
import AppKit
import Foundation
import CapturePointCore

enum PermissionChecker {
    private static let audioCaptureKey = "capturepoint.audioCaptureLastGranted"
    private static let legacyAudioCaptureKey = "snappath.audioCaptureLastGranted"

    static func snapshot(
        wantsOnScreenAudio: Bool,
        wantsMicrophone: Bool,
        os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> PermissionSnapshot {
        let screen: PermissionState = CaptureService.hasScreenRecordingAccess() ? .granted : .notDetermined
        let last = (UserDefaults.standard.object(forKey: audioCaptureKey) as? Bool)
            ?? (UserDefaults.standard.object(forKey: legacyAudioCaptureKey) as? Bool)
        let audio = PermissionPolicy.audioCaptureState(os: os, lastGranted: last)
        let microphone: PermissionState
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphone = .granted
        case .denied, .restricted:
            microphone = .denied
        case .notDetermined:
            microphone = .notDetermined
        @unknown default:
            microphone = .unknown("Microphone status is unavailable.")
        }
        return PermissionSnapshot(
            screenRecording: screen,
            audioCapture: audio,
            microphone: microphone,
            wantsOnScreenAudio: wantsOnScreenAudio,
            wantsMicrophone: wantsMicrophone
        )
    }

    static func rememberAudioCapture(granted: Bool) {
        UserDefaults.standard.set(granted, forKey: audioCaptureKey)
    }

    static func openSettings(for kind: AppPermission) {
        let path: String
        switch kind {
        case .screenRecording:
            path = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .audioCapture:
            path = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        case .microphone:
            path = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        }
        if let url = URL(string: path) {
            NSWorkspace.shared.open(url)
        }
    }
}
