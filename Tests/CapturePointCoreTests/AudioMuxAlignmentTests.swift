import XCTest
@testable import CapturePointCore

final class AudioMuxAlignmentTests: XCTestCase {
    func testDurationLeadSkipsTapPreroll() {
        XCTAssertEqual(
            AudioMuxAlignment.lead(audioDuration: 10, videoDuration: 8, hintedLead: 0),
            1.94,
            accuracy: 0.0001
        )
    }

    func testImplausibleHintIsIgnored() {
        XCTAssertEqual(
            AudioMuxAlignment.lead(audioDuration: 10, videoDuration: 8, hintedLead: 3),
            1.94,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioMuxAlignment.lead(audioDuration: 293.835, videoDuration: 292.542, hintedLead: 180.057),
            1.233,
            accuracy: 0.0001
        )
    }

    func testSmallerPlausibleHintIsKept() {
        XCTAssertEqual(
            AudioMuxAlignment.lead(audioDuration: 10, videoDuration: 8, hintedLead: 1.0),
            1.0,
            accuracy: 0.0001
        )
    }

    func testNegativeLeadsClampToZero() {
        XCTAssertEqual(
            AudioMuxAlignment.lead(audioDuration: 5, videoDuration: 8, hintedLead: -1),
            0,
            accuracy: 0.0001
        )
    }

    func testHintedLeadFromClocks() {
        let audio = Date(timeIntervalSince1970: 1_000)
        let video = Date(timeIntervalSince1970: 1_002)
        XCTAssertEqual(
            AudioMuxAlignment.hintedLead(audioStarted: audio, videoStarted: video),
            1.96,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioMuxAlignment.hintedLead(audioStarted: video, videoStarted: audio),
            0,
            accuracy: 0.0001
        )
    }

    func testUsableRangeRejectedWhenAudioIsTooShort() {
        XCTAssertNil(
            AudioMuxAlignment.usableAudioRange(audioDuration: 1, videoDuration: 8, lead: 0.98)
        )
        let range = AudioMuxAlignment.usableAudioRange(
            audioDuration: 10,
            videoDuration: 8,
            lead: 1.94
        )
        XCTAssertEqual(range?.start ?? -1, 1.94, accuracy: 0.0001)
        XCTAssertEqual(range?.duration ?? -1, 8, accuracy: 0.0001)
    }
}
