import Foundation

public enum AppPermission: String, CaseIterable, Identifiable, Sendable {
    case screenRecording
    case audioCapture
    case microphone

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .audioCapture: return "Audio Capture"
        case .microphone: return "Microphone"
        }
    }

    public var summary: String {
        switch self {
        case .screenRecording:
            return "Required for every screenshot and recording."
        case .audioCapture:
            return "Required for on-screen audio (the sound of videos and apps). Needs macOS 14.2 or later."
        case .microphone:
            return "Optional. Used only when Record microphone is on."
        }
    }
}

public enum PermissionState: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
    case unavailable(String)
    case unknown(String)

    public var title: String {
        switch self {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not granted"
        case .unavailable: return "Unavailable"
        case .unknown: return "Will ask when needed"
        }
    }

    public var needsAttention: Bool {
        switch self {
        case .granted, .unknown: return false
        case .denied, .notDetermined, .unavailable: return true
        }
    }
}

public struct PermissionSnapshot: Equatable, Sendable {
    public var screenRecording: PermissionState
    public var audioCapture: PermissionState
    public var microphone: PermissionState
    public var wantsOnScreenAudio: Bool
    public var wantsMicrophone: Bool

    public init(
        screenRecording: PermissionState,
        audioCapture: PermissionState,
        microphone: PermissionState,
        wantsOnScreenAudio: Bool,
        wantsMicrophone: Bool
    ) {
        self.screenRecording = screenRecording
        self.audioCapture = audioCapture
        self.microphone = microphone
        self.wantsOnScreenAudio = wantsOnScreenAudio
        self.wantsMicrophone = wantsMicrophone
    }

    public static let checking = PermissionSnapshot(
        screenRecording: .unknown("Checking…"),
        audioCapture: .unknown("Checking…"),
        microphone: .unknown("Checking…"),
        wantsOnScreenAudio: true,
        wantsMicrophone: false
    )

    public var needsAttention: Bool {
        PermissionPolicy.needsAttention(
            screen: screenRecording,
            audio: audioCapture,
            microphone: microphone,
            wantsOnScreenAudio: wantsOnScreenAudio,
            wantsMicrophone: wantsMicrophone
        )
    }
}

public enum PermissionPolicy {
    public static let onScreenAudioMinimum = OperatingSystemVersion(
        majorVersion: 14,
        minorVersion: 2,
        patchVersion: 0
    )

    public static func supportsOnScreenAudio(_ version: OperatingSystemVersion) -> Bool {
        if version.majorVersion != onScreenAudioMinimum.majorVersion {
            return version.majorVersion > onScreenAudioMinimum.majorVersion
        }
        if version.minorVersion != onScreenAudioMinimum.minorVersion {
            return version.minorVersion > onScreenAudioMinimum.minorVersion
        }
        return version.patchVersion >= onScreenAudioMinimum.patchVersion
    }

    public static func audioCaptureState(
        os: OperatingSystemVersion,
        lastGranted: Bool?
    ) -> PermissionState {
        guard supportsOnScreenAudio(os) else {
            return .unavailable(
                "On-screen audio needs macOS 14.2 or later. Recordings on this Mac are picture-only unless you use the microphone."
            )
        }
        if let lastGranted {
            return lastGranted ? .granted : .denied
        }
        return .unknown("macOS will ask the first time you record with on-screen audio.")
    }

    public static func needsAttention(
        screen: PermissionState,
        audio: PermissionState,
        microphone: PermissionState,
        wantsOnScreenAudio: Bool,
        wantsMicrophone: Bool
    ) -> Bool {
        if screen != .granted { return true }
        if wantsOnScreenAudio {
            switch audio {
            case .granted, .unknown:
                break
            case .denied, .notDetermined, .unavailable:
                return true
            }
        }
        if wantsMicrophone {
            switch microphone {
            case .granted, .unknown:
                break
            case .denied, .notDetermined, .unavailable:
                return true
            }
        }
        return false
    }
}
