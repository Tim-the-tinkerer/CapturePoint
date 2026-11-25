import Foundation

public enum CapturedMediaKind: String, Sendable {
    case still
    case recording
}

public enum CaptureOutcome: Equatable, Sendable {
    case cancelled
    case ready(url: URL, byteCount: Int64)
}

/// Decides whether a temp capture is keepable, and where it should land.
public enum CaptureFinalizer {
    public static let minimumStillBytes: Int64 = 1
    public static let minimumRecordingBytes: Int64 = 1024

    public static func minimumBytes(for kind: CapturedMediaKind) -> Int64 {
        switch kind {
        case .still: return minimumStillBytes
        case .recording: return minimumRecordingBytes
        }
    }

    public static func outcome(
        temporaryFile url: URL?,
        kind: CapturedMediaKind,
        fileManager: FileManager = .default
    ) -> CaptureOutcome {
        guard let url else { return .cancelled }
        guard fileManager.fileExists(atPath: url.path) else { return .cancelled }
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= minimumBytes(for: kind) else { return .cancelled }
        return .ready(url: url, byteCount: size)
    }

    public static func suggestedName(
        kind: CapturedMediaKind,
        existingFilenames: Set<String>,
        format: ImageFormat = .png,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        switch kind {
        case .still:
            return FilenameGenerator.makeFilename(
                now: now,
                format: format,
                existingFilenames: existingFilenames,
                timeZone: timeZone
            )
        case .recording:
            return FilenameGenerator.makeRecordingFilename(
                now: now,
                existingFilenames: existingFilenames,
                timeZone: timeZone
            )
        }
    }

    public static func suggestedDestination(
        folder: URL,
        existingFilenames: Set<String>,
        kind: CapturedMediaKind,
        format: ImageFormat = .png,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> URL {
        folder.appendingPathComponent(
            suggestedName(
                kind: kind,
                existingFilenames: existingFilenames,
                format: format,
                now: now,
                timeZone: timeZone
            )
        )
    }
}
