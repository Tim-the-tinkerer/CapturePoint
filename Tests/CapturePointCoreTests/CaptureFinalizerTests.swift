import XCTest
@testable import CapturePointCore

final class CaptureFinalizerTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapturePoint-Finalize-\(UUID().uuidString)", isDirectory: true)
        try FileDestination.ensureFolder(scratch)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testNilAndMissingFilesAreCancelled() {
        XCTAssertEqual(CaptureFinalizer.outcome(temporaryFile: nil, kind: .still), .cancelled)
        let missing = scratch.appendingPathComponent("gone.png")
        XCTAssertEqual(CaptureFinalizer.outcome(temporaryFile: missing, kind: .still), .cancelled)
    }

    func testEmptyStillAndTinyRecordingAreCancelled() throws {
        let empty = scratch.appendingPathComponent("empty.png")
        try Data().write(to: empty)
        XCTAssertEqual(CaptureFinalizer.outcome(temporaryFile: empty, kind: .still), .cancelled)

        let tiny = scratch.appendingPathComponent("tiny.mov")
        try Data(repeating: 0, count: 512).write(to: tiny)
        XCTAssertEqual(CaptureFinalizer.outcome(temporaryFile: tiny, kind: .recording), .cancelled)
    }

    func testKeepableFilesAreReady() throws {
        let still = scratch.appendingPathComponent("shot.png")
        try Data([0x89, 0x50]).write(to: still)
        XCTAssertEqual(
            CaptureFinalizer.outcome(temporaryFile: still, kind: .still),
            .ready(url: still, byteCount: 2)
        )

        let movie = scratch.appendingPathComponent("clip.mov")
        try Data(repeating: 1, count: 2048).write(to: movie)
        XCTAssertEqual(
            CaptureFinalizer.outcome(temporaryFile: movie, kind: .recording),
            .ready(url: movie, byteCount: 2048)
        )
    }

    func testSuggestedDestinationAvoidsCollisions() {
        let tz = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let date = calendar.date(from: DateComponents(
            calendar: calendar, timeZone: tz,
            year: 2026, month: 8, day: 16, hour: 14, minute: 32, second: 5
        ))!

        let dest = CaptureFinalizer.suggestedDestination(
            folder: scratch,
            existingFilenames: [
                "Screenshot 2026-08-16 at 14.32.05.png",
                "Recording 2026-08-16 at 14.32.05.mov",
            ],
            kind: .still,
            format: .png,
            now: date,
            timeZone: tz
        )
        XCTAssertEqual(dest.lastPathComponent, "Screenshot 2026-08-16 at 14.32.05 (2).png")

        let rec = CaptureFinalizer.suggestedDestination(
            folder: scratch,
            existingFilenames: ["Recording 2026-08-16 at 14.32.05.mov"],
            kind: .recording,
            now: date,
            timeZone: tz
        )
        XCTAssertEqual(rec.lastPathComponent, "Recording 2026-08-16 at 14.32.05 (2).mov")
    }
}
