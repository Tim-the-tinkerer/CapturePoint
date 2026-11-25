import Foundation
import CapturePointCore

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var shots: [ShotRecord] = []
    @Published private(set) var loadWarning: String?

    private var archive: HistoryArchive

    init(fileURL: URL? = nil) {
        if let fileURL {
            archive = HistoryArchive.load(from: fileURL)
        } else {
            do {
                archive = HistoryArchive.load(from: try HistoryArchive.defaultFileURL())
            } catch {
                let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    .appendingPathComponent("CapturePoint-history.json")
                archive = HistoryArchive.load(from: fallback)
                loadWarning = "Could not use Application Support (\(error.localizedDescription)); using a temporary Recent list."
            }
        }
        shots = archive.shots
        if loadWarning == nil {
            loadWarning = archive.lastLoadError
        }
        if archive.lastLoadError == nil {
            do {
                try archive.pruneMissing()
                shots = archive.shots
            } catch {
                loadWarning = error.localizedDescription
            }
        }
    }

    func add(url: URL) throws {
        try archive.add(url: url)
        publish()
    }

    func remove(_ id: UUID) throws {
        try archive.remove(id)
        publish()
    }

    func trash(_ record: ShotRecord) throws {
        try archive.trash(record)
        publish()
    }

    func clear() throws {
        try archive.clear()
        publish()
    }

    func pruneMissing() throws {
        try archive.pruneMissing()
        publish()
    }

    private func publish() {
        shots = archive.shots
        loadWarning = archive.lastLoadError
    }
}
