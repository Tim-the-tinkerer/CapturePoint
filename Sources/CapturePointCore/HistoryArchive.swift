import Foundation

/// Persistent Recent list. Does not delete files except via `trash`.
///
/// If `history.json` is corrupt, the file is left in place and writes are
/// blocked until `clear()` recovers it.
public struct HistoryArchive: Equatable {
    public var shots: [ShotRecord]
    public let fileURL: URL
    public let limit: Int
    public private(set) var lastLoadError: String?

    public init(
        fileURL: URL,
        limit: Int = 40,
        shots: [ShotRecord] = [],
        lastLoadError: String? = nil
    ) {
        self.fileURL = fileURL
        self.limit = limit
        self.shots = shots
        self.lastLoadError = lastLoadError
    }

    public static func defaultFileURL(fileManager: FileManager = .default) throws -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = support.appendingPathComponent("CapturePoint", isDirectory: true)
        try FileDestination.ensureFolder(dir, fileManager: fileManager)
        let file = dir.appendingPathComponent("history.json")
        if !fileManager.fileExists(atPath: file.path) {
            let legacy = support
                .appendingPathComponent("SnapPath", isDirectory: true)
                .appendingPathComponent("history.json")
            if fileManager.fileExists(atPath: legacy.path) {
                try? fileManager.copyItem(at: legacy, to: file)
            }
        }
        return file
    }

    public static func load(from fileURL: URL, fileManager: FileManager = .default, limit: Int = 40) -> HistoryArchive {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return HistoryArchive(fileURL: fileURL, limit: limit)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try Self.decoder.decode([ShotRecord].self, from: data)
            return HistoryArchive(fileURL: fileURL, limit: limit, shots: decoded)
        } catch {
            return HistoryArchive(
                fileURL: fileURL,
                limit: limit,
                lastLoadError: "Could not read Recent history: \(error.localizedDescription)"
            )
        }
    }

    public mutating func add(url: URL, fileManager: FileManager = .default) throws {
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let record = ShotRecord(path: url.path, byteCount: size)
        let cap = limit
        try updateShots(fileManager: fileManager) { shots in
            shots.removeAll { $0.path == url.path }
            shots.insert(record, at: 0)
            if shots.count > cap {
                shots = Array(shots.prefix(cap))
            }
        }
    }

    public mutating func remove(_ id: UUID, fileManager: FileManager = .default) throws {
        try updateShots(fileManager: fileManager) { shots in
            shots.removeAll { $0.id == id }
        }
    }

    public mutating func trash(_ record: ShotRecord, fileManager: FileManager = .default) throws {
        let url = record.url
        if fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
            } catch {
                throw CaptureError.trashFailed(
                    "Could not move \(record.filename) to Trash: \(error.localizedDescription)"
                )
            }
        }
        try remove(record.id, fileManager: fileManager)
    }

    public mutating func clear(fileManager: FileManager = .default) throws {
        let previousShots = shots
        let previousError = lastLoadError
        shots = []
        lastLoadError = nil
        do {
            try save(fileManager: fileManager)
        } catch {
            shots = previousShots
            lastLoadError = previousError
            throw error
        }
    }

    public mutating func pruneMissing(fileManager: FileManager = .default) throws {
        let kept = shots.filter { shot in
            if fileManager.fileExists(atPath: shot.path) { return true }
            // An ejected drive should come back with its Recent rows intact.
            return !Self.isOnMountedVolume(path: shot.path, fileManager: fileManager)
        }
        guard kept != shots else { return }
        try updateShots(fileManager: fileManager) { shots in
            shots = kept
        }
    }

    /// A path under `/Volumes/Name` is mounted only when that volume is in the
    /// current mount list. Everything else is treated as the boot volume.
    static func isOnMountedVolume(path: String, fileManager: FileManager = .default) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized.hasPrefix("/Volumes/") else { return true }
        let parts = standardized.split(separator: "/")
        guard parts.count >= 2, parts[0] == "Volumes" else { return true }
        let volumePath = "/Volumes/\(parts[1])"
        let mounted = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return mounted.contains { volume in
            var root = volume.standardizedFileURL.path
            if root.count > 1, root.hasSuffix("/") {
                root.removeLast()
            }
            return root.caseInsensitiveCompare(volumePath) == .orderedSame
        }
    }

    private mutating func updateShots(
        fileManager: FileManager,
        _ body: (inout [ShotRecord]) -> Void
    ) throws {
        if lastLoadError != nil {
            try save(fileManager: fileManager)
        }
        let previous = shots
        body(&shots)
        do {
            try save(fileManager: fileManager)
        } catch {
            shots = previous
            throw error
        }
    }

    public func save(fileManager: FileManager = .default) throws {
        if let lastLoadError {
            throw CaptureError.historyWriteFailed(lastLoadError)
        }
        if let parent = FileDestination.parentDirectory(of: fileURL) {
            try FileDestination.ensureFolder(parent, fileManager: fileManager)
        }
        do {
            let data = try Self.encoder.encode(shots)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw CaptureError.historyWriteFailed("Could not save Recent history: \(error.localizedDescription)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
