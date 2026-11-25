import XCTest
@testable import CapturePointCore

final class PermissionPolicyTests: XCTestCase {
    func testOnScreenAudioRequiresMacOS142() {
        XCTAssertFalse(PermissionPolicy.supportsOnScreenAudio(
            OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 7)
        ))
        XCTAssertFalse(PermissionPolicy.supportsOnScreenAudio(
            OperatingSystemVersion(majorVersion: 14, minorVersion: 1, patchVersion: 2)
        ))
        XCTAssertTrue(PermissionPolicy.supportsOnScreenAudio(
            OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)
        ))
        XCTAssertTrue(PermissionPolicy.supportsOnScreenAudio(
            OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        ))
    }

    func testAudioStateUnavailableBefore142() {
        let state = PermissionPolicy.audioCaptureState(
            os: OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0),
            lastGranted: true
        )
        guard case .unavailable = state else {
            return XCTFail("expected unavailable, got \(state)")
        }
    }

    func testAudioStateRemembersLastTap() {
        XCTAssertEqual(
            PermissionPolicy.audioCaptureState(
                os: OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0),
                lastGranted: true
            ),
            .granted
        )
        XCTAssertEqual(
            PermissionPolicy.audioCaptureState(
                os: OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0),
                lastGranted: false
            ),
            .denied
        )
        guard case .unknown = PermissionPolicy.audioCaptureState(
            os: OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0),
            lastGranted: nil
        ) else {
            return XCTFail("expected unknown before first tap")
        }
    }

    func testAttentionSeparatesTheThreePermissions() {
        XCTAssertTrue(PermissionPolicy.needsAttention(
            screen: .notDetermined,
            audio: .granted,
            microphone: .granted,
            wantsOnScreenAudio: true,
            wantsMicrophone: false
        ))
        XCTAssertTrue(PermissionPolicy.needsAttention(
            screen: .granted,
            audio: .denied,
            microphone: .granted,
            wantsOnScreenAudio: true,
            wantsMicrophone: false
        ))
        XCTAssertFalse(PermissionPolicy.needsAttention(
            screen: .granted,
            audio: .denied,
            microphone: .granted,
            wantsOnScreenAudio: false,
            wantsMicrophone: false
        ))
        XCTAssertTrue(PermissionPolicy.needsAttention(
            screen: .granted,
            audio: .granted,
            microphone: .denied,
            wantsOnScreenAudio: false,
            wantsMicrophone: true
        ))
        XCTAssertFalse(PermissionPolicy.needsAttention(
            screen: .granted,
            audio: .unknown("will ask"),
            microphone: .notDetermined,
            wantsOnScreenAudio: true,
            wantsMicrophone: false
        ))
    }

    func testPermissionCopyIsSpecific() {
        XCTAssertEqual(AppPermission.screenRecording.title, "Screen Recording")
        XCTAssertEqual(AppPermission.audioCapture.title, "Audio Capture")
        XCTAssertEqual(AppPermission.microphone.title, "Microphone")
        XCTAssertTrue(AppPermission.audioCapture.summary.contains("14.2"))
        XCTAssertFalse(AppPermission.screenRecording.summary.contains("microphone"))
    }
}
