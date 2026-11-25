import XCTest
@testable import CapturePointCore

final class HistoryArchiveTests: XCTestCase {
    private var scratch: URL!
    private var historyURL: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapturePoint-History-\(UUID().uuidString)", isDirectory: true)
        try FileDestination.ensureFolder(scratch)
        historyURL = scratch.appendingPathComponent("history.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    @discardableResult
    private func writeFile(_ name: String, bytes: Int = 4) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func testAddNewestFirstAndDedupePath() throws {
        var archive = HistoryArchive(fileURL: historyURL, limit: 3)
        let first = try writeFile("a.png")
        let second = try writeFile("b.png")
        try archive.add(url: first)
        try archive.add(url: second)
        try archive.add(url: first)
        XCTAssertEqual(archive.shots.map(\.filename), ["a.png", "b.png"])
    }

    func testLimitDropsOldest() throws {
        var archive = HistoryArchive(fileURL: historyURL, limit: 2)
        try archive.add(url: writeFile("a.png"))
        try archive.add(url: writeFile("b.png"))
        try archive.add(url: writeFile("c.png"))
        XCTAssertEqual(archive.shots.map(\.filename), ["c.png", "b.png"])
    }

    func testPersistAndReload() throws {
        var archive = HistoryArchive(fileURL: historyURL)
        let shot = try writeFile("keep.png")
        try archive.add(url: shot)
        let loaded = HistoryArchive.load(from: historyURL)
        XCTAssertEqual(loaded.shots.count, 1)
        XCTAssertEqual(loaded.shots[0].path, shot.path)
        XCTAssertNil(loaded.lastLoadError)
    }

    func testMissingFileStartsEmpty() {
        let loaded = HistoryArchive.load(from: historyURL)
        XCTAssertTrue(loaded.shots.isEmpty)
        XCTAssertNil(loaded.lastLoadError)
    }

    func testCorruptJSONBlocksWritesAndSurvivesUntilClear() throws {
        try Data("not-json".utf8).write(to: historyURL)
        var archive = HistoryArchive.load(from: historyURL)
        XCTAssertNotNil(archive.lastLoadError)
        XCTAssertTrue(archive.shots.isEmpty)

        XCTAssertThrowsError(try archive.add(url: writeFile("new.png")))
        XCTAssertEqual(try String(contentsOf: historyURL, encoding: .utf8), "not-json")

        try archive.clear()
        XCTAssertNil(archive.lastLoadError)
        XCTAssertTrue(archive.shots.isEmpty)
        let decoded = try JSONDecoder().decode([ShotRecord].self, from: Data(contentsOf: historyURL))
        XCTAssertTrue(decoded.isEmpty)
    }

    func testPruneMissingRemovesGoneFiles() throws {
        var archive = HistoryArchive(fileURL: historyURL)
        let keep = try writeFile("keep.png")
        let gone = try writeFile("gone.png")
        try archive.add(url: gone)
        try archive.add(url: keep)
        try FileManager.default.removeItem(at: gone)
        try archive.pruneMissing()
        XCTAssertEqual(archive.shots.map(\.filename), ["keep.png"])
    }

    func testClearDoesNotDeleteFiles() throws {
        var archive = HistoryArchive(fileURL: historyURL)
        let shot = try writeFile("stay.png")
        try archive.add(url: shot)
        try archive.clear()
        XCTAssertTrue(FileManager.default.fileExists(atPath: shot.path))
        XCTAssertTrue(archive.shots.isEmpty)
    }

    func testTrashMovesFileAndUnlists() throws {
        var archive = HistoryArchive(fileURL: historyURL)
        let shot = try writeFile("trash-me.png")
        try archive.add(url: shot)
        try archive.trash(archive.shots[0])
        XCTAssertTrue(archive.shots.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shot.path))
    }

    func testAddRollsBackWhenTheHistoryFileCannotBeWritten() throws {
        let blocker = scratch.appendingPathComponent("blocker")
        try Data([1]).write(to: blocker)
        var archive = HistoryArchive(fileURL: blocker.appendingPathComponent("history.json"))
        let shot = try writeFile("a.png")
        XCTAssertThrowsError(try archive.add(url: shot))
        XCTAssertTrue(archive.shots.isEmpty)
    }

    func testClearRestoresACorruptHistoryWhenSaveFails() throws {
        let blocker = scratch.appendingPathComponent("blocker")
        try Data([1]).write(to: blocker)
        var archive = HistoryArchive(
            fileURL: blocker.appendingPathComponent("history.json"),
            shots: [ShotRecord(path: "/tmp/a.png", byteCount: 1)],
            lastLoadError: "Could not read Recent history: bad"
        )
        XCTAssertThrowsError(try archive.clear())
        XCTAssertEqual(archive.shots.count, 1)
        XCTAssertNotNil(archive.lastLoadError)
    }

    func testPruneKeepsShotsOnAnUnmountedVolume() throws {
        var archive = HistoryArchive(fileURL: historyURL)
        let keep = try writeFile("keep.png")
        let unplugged = "/Volumes/CapturePointNoSuchDisk-\(UUID().uuidString)/shot.png"
        archive.shots = [
            ShotRecord(path: keep.path, byteCount: 4),
            ShotRecord(path: unplugged, byteCount: 4),
        ]
        try archive.save()
        try archive.pruneMissing()
        XCTAssertEqual(archive.shots.map(\.path).sorted(), [keep.path, unplugged].sorted())
    }

    func testTrashOfMissingFileJustUnlists() throws {
        var archive = HistoryArchive(fileURL: historyURL)
        let shot = try writeFile("already-gone.png")
        try archive.add(url: shot)
        try FileManager.default.removeItem(at: shot)
        try archive.trash(archive.shots[0])
        XCTAssertTrue(archive.shots.isEmpty)
    }
}
