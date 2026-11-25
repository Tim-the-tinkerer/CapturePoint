import XCTest
@testable import CapturePointCore

final class FileDestinationTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapturePoint-Dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testEnsureFolderCreatesNestedPath() throws {
        let nested = scratch.appendingPathComponent("Pictures/Screenshots", isDirectory: true)
        try FileDestination.ensureFolder(nested)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testEnsureFolderFailsWhenAFileIsInTheWay() throws {
        let blocker = scratch.appendingPathComponent("not-a-folder")
        try Data([1]).write(to: blocker)
        XCTAssertThrowsError(try FileDestination.ensureFolder(blocker)) { error in
            guard let capture = error as? CaptureError,
                  case .folderCreateFailed(let url, _) = capture else {
                return XCTFail("expected folderCreateFailed, got \(error)")
            }
            XCTAssertEqual(url.path, blocker.path)
        }
    }

    func testMoveReplacingCreatesANewFile() throws {
        let from = scratch.appendingPathComponent("from.png")
        let to = scratch.appendingPathComponent("fresh.png")
        try Data([1, 2]).write(to: from)
        try FileDestination.moveReplacing(from: from, to: to)
        XCTAssertFalse(FileManager.default.fileExists(atPath: from.path))
        XCTAssertEqual(try Data(contentsOf: to), Data([1, 2]))
    }

    func testMoveReplacingKeepsTheOldFileWhenTheSourceIsMissing() throws {
        let from = scratch.appendingPathComponent("missing.png")
        let to = scratch.appendingPathComponent("kept.png")
        try Data([9]).write(to: to)
        XCTAssertThrowsError(try FileDestination.moveReplacing(from: from, to: to))
        XCTAssertEqual(try Data(contentsOf: to), Data([9]))
    }

    func testMoveReplacingOverwritesExisting() throws {
        let from = scratch.appendingPathComponent("from.png")
        let to = scratch.appendingPathComponent("to.png")
        try Data([1, 2, 3]).write(to: from)
        try Data([9]).write(to: to)
        try FileDestination.moveReplacing(from: from, to: to)
        XCTAssertFalse(FileManager.default.fileExists(atPath: from.path))
        XCTAssertEqual(try Data(contentsOf: to), Data([1, 2, 3]))
    }

    func testFilenamesThrowsWhenDirectoryMissing() {
        let missing = scratch.appendingPathComponent("nope", isDirectory: true)
        XCTAssertThrowsError(try FilenameGenerator.filenames(in: missing)) { error in
            guard let capture = error as? CaptureError,
                  case .folderUnreadable = capture else {
                return XCTFail("expected folderUnreadable, got \(error)")
            }
        }
    }
}
