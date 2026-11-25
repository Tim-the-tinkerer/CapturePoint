import XCTest
@testable import CapturePointCore

final class FilenameGeneratorTests: XCTestCase {
    func testFormattedBaseUsesPOSIXDateAndDottedTime() {
        let tz = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let parts = DateComponents(calendar: calendar, timeZone: tz, year: 2026, month: 8, day: 16, hour: 14, minute: 32, second: 5)
        let date = calendar.date(from: parts)!
        XCTAssertEqual(
            FilenameGenerator.formattedBase(now: date, timeZone: tz),
            "Screenshot 2026-08-16 at 14.32.05"
        )
    }

    func testUniqueNameAppendsIndexOnCollision() {
        XCTAssertEqual(
            FilenameGenerator.uniqueName(base: "Shot", ext: "png", existing: []),
            "Shot.png"
        )
        XCTAssertEqual(
            FilenameGenerator.uniqueName(base: "Shot", ext: ".png", existing: ["Shot.png"]),
            "Shot (2).png"
        )
        XCTAssertEqual(
            FilenameGenerator.uniqueName(
                base: "Shot",
                ext: "png",
                existing: ["Shot.png", "Shot (2).png"]
            ),
            "Shot (3).png"
        )
    }

    func testUniqueNameIsCaseInsensitive() {
        XCTAssertEqual(
            FilenameGenerator.uniqueName(base: "Shot", ext: "png", existing: ["shot.PNG"]),
            "Shot (2).png"
        )
    }

    func testTildePath() {
        let home = "/Users/demo"
        XCTAssertEqual(
            PathDisplay.tildePath(
                URL(fileURLWithPath: "/Users/demo/Pictures/Screenshots", isDirectory: true),
                home: home
            ),
            "~/Pictures/Screenshots"
        )
        XCTAssertEqual(
            PathDisplay.tildePath(URL(fileURLWithPath: "/Users/demo", isDirectory: true), home: home),
            "~"
        )
        XCTAssertEqual(
            PathDisplay.tildePath(URL(fileURLWithPath: "/tmp/out", isDirectory: true), home: home),
            "/tmp/out"
        )
    }

    func testRecordingFilenameAndVideoDetection() {
        let tz = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let parts = DateComponents(calendar: calendar, timeZone: tz, year: 2026, month: 8, day: 16, hour: 14, minute: 32, second: 5)
        let date = calendar.date(from: parts)!
        XCTAssertEqual(
            FilenameGenerator.makeRecordingFilename(now: date, existingFilenames: [], timeZone: tz),
            "Recording 2026-08-16 at 14.32.05.mov"
        )
        XCTAssertTrue(ShotRecord.isVideoPath("/tmp/clip.MOV"))
        XCTAssertFalse(ShotRecord.isVideoPath("/tmp/shot.png"))
        XCTAssertEqual(PathDisplay.clock(75), "1:15")
    }

    func testDisplayFilenamesKeepThePrimaryAndMarkTheRest() {
        XCTAssertEqual(CaptureLayout.filename(primary: "Shot.png", displayIndex: 1), "Shot.png")
        XCTAssertEqual(
            CaptureLayout.filename(primary: "Screenshot 2026-08-16 at 14.32.05.png", displayIndex: 2),
            "Screenshot 2026-08-16 at 14.32.05 Display 2.png"
        )
        let primary = URL(fileURLWithPath: "/tmp/clip.mov")
        XCTAssertEqual(CaptureLayout.url(primary, displayIndex: 1).path, "/tmp/clip.mov")
        XCTAssertEqual(CaptureLayout.url(primary, displayIndex: 3).lastPathComponent, "clip Display 3.mov")
    }

    func testSelfTestPasses() {
        XCTAssertNil(SelfTest.run())
    }
}
