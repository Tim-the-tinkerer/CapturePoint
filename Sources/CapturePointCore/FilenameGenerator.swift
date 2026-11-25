import Foundation

public enum FilenameGenerator {
    public static let prefix = "Screenshot"

    public static let recordingPrefix = "Recording"
    public static let recordingExtension = "mov"

    public static func formattedBase(
        now: Date,
        prefix: String = prefix,
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "en_US_POSIX")
    ) -> String {
        let date = DateFormatter()
        date.locale = locale
        date.timeZone = timeZone
        date.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = timeZone
        time.dateFormat = "HH.mm.ss"
        return "\(prefix) \(date.string(from: now)) at \(time.string(from: now))"
    }

    /// Returns a filename that does not collide with `existing` (filenames only, not paths).
    public static func uniqueName(
        base: String,
        ext: String,
        existing: Set<String>
    ) -> String {
        let cleanExt = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        let first = "\(base).\(cleanExt)"
        if !contains(existing, first) {
            return first
        }
        var n = 2
        while true {
            let candidate = "\(base) (\(n)).\(cleanExt)"
            if !contains(existing, candidate) {
                return candidate
            }
            n += 1
        }
    }

    public static func makeFilename(
        now: Date = Date(),
        format: ImageFormat,
        existingFilenames: Set<String>,
        timeZone: TimeZone = .current
    ) -> String {
        uniqueName(
            base: formattedBase(now: now, prefix: prefix, timeZone: timeZone),
            ext: format.fileExtension,
            existing: existingFilenames
        )
    }

    public static func makeRecordingFilename(
        now: Date = Date(),
        existingFilenames: Set<String>,
        timeZone: TimeZone = .current
    ) -> String {
        uniqueName(
            base: formattedBase(now: now, prefix: recordingPrefix, timeZone: timeZone),
            ext: recordingExtension,
            existing: existingFilenames
        )
    }

    public static func filenames(in directory: URL, fileManager: FileManager = .default) throws -> Set<String> {
        do {
            return Set(try fileManager.contentsOfDirectory(atPath: directory.path))
        } catch {
            throw CaptureError.folderUnreadable(directory, error.localizedDescription)
        }
    }

    private static func contains(_ existing: Set<String>, _ name: String) -> Bool {
        if existing.contains(name) { return true }
        let lower = name.lowercased()
        return existing.contains { $0.lowercased() == lower }
    }
}

/// Names for the extra displays in one full-screen capture.
/// Display 1 keeps the primary filename. Later displays insert " Display N"
/// before the extension.
public enum CaptureLayout {
    public static func filename(primary: String, displayIndex: Int) -> String {
        guard displayIndex > 1 else { return primary }
        let url = URL(fileURLWithPath: primary)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let named = "\(base) Display \(displayIndex)"
        return ext.isEmpty ? named : "\(named).\(ext)"
    }

    public static func url(_ primary: URL, displayIndex: Int) -> URL {
        let name = filename(primary: primary.lastPathComponent, displayIndex: displayIndex)
        return primary.deletingLastPathComponent().appendingPathComponent(name)
    }
}

public enum SelfTest {
    /// Returns `nil` on success, or a failure message.
    public static func run() -> String? {
        let tz = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let parts = DateComponents(calendar: calendar, timeZone: tz, year: 2026, month: 8, day: 16, hour: 14, minute: 32, second: 5)
        guard let date = calendar.date(from: parts) else {
            return "formattedBase: could not build sample date"
        }
        let base = FilenameGenerator.formattedBase(now: date, timeZone: tz)
        let expectedBase = "Screenshot 2026-08-16 at 14.32.05"
        if base != expectedBase {
            return "formattedBase: got \(base), expected \(expectedBase)"
        }

        let first = FilenameGenerator.uniqueName(base: "Shot", ext: "png", existing: [])
        if first != "Shot.png" {
            return "uniqueName empty: got \(first)"
        }

        let second = FilenameGenerator.uniqueName(
            base: "Shot",
            ext: "png",
            existing: ["Shot.png", "Shot (2).png"]
        )
        if second != "Shot (3).png" {
            return "uniqueName collision: got \(second)"
        }

        let caseClash = FilenameGenerator.uniqueName(
            base: "Shot",
            ext: "png",
            existing: ["shot.PNG"]
        )
        if caseClash != "Shot (2).png" {
            return "uniqueName case: got \(caseClash)"
        }

        let home = "/Users/demo"
        let tiled = PathDisplay.tildePath(
            URL(fileURLWithPath: "/Users/demo/Pictures/Screenshots", isDirectory: true),
            home: home
        )
        if tiled != "~/Pictures/Screenshots" {
            return "tildePath: got \(tiled)"
        }

        let outside = PathDisplay.tildePath(
            URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            home: home
        )
        if outside != "/tmp/out" {
            return "tildePath outside home: got \(outside)"
        }

        let bytes = PathDisplay.byteCount(1_500_000)
        if !bytes.contains("MB") || bytes.isEmpty {
            return "byteCount: got \(bytes)"
        }

        let recBase = FilenameGenerator.formattedBase(now: date, prefix: FilenameGenerator.recordingPrefix, timeZone: tz)
        if recBase != "Recording 2026-08-16 at 14.32.05" {
            return "recording base: got \(recBase)"
        }
        let recName = FilenameGenerator.makeRecordingFilename(now: date, existingFilenames: [], timeZone: tz)
        if recName != "Recording 2026-08-16 at 14.32.05.mov" {
            return "recording filename: got \(recName)"
        }
        if !ShotRecord.isVideoPath("/tmp/clip.MOV") {
            return "video path detection"
        }
        if ShotRecord.isVideoPath("/tmp/shot.png") {
            return "png should not be video"
        }
        if PathDisplay.clock(75) != "1:15" {
            return "clock: got \(PathDisplay.clock(75))"
        }

        if ImageFormat.jpeg.fileExtension != "jpg" {
            return "jpeg extension"
        }
        if FolderPreset.screenshots.url(home: URL(fileURLWithPath: "/Users/demo", isDirectory: true)).path
            != "/Users/demo/Pictures/Screenshots" {
            return "screenshots preset path"
        }
        if CaptureLayout.filename(primary: "Shot.png", displayIndex: 1) != "Shot.png" {
            return "display filename primary"
        }
        if CaptureLayout.filename(primary: "Shot.png", displayIndex: 2) != "Shot Display 2.png" {
            return "display filename second"
        }

        if AudioMuxAlignment.lead(audioDuration: 10, videoDuration: 8, hintedLead: 0) != 1.94 {
            return "mux lead from durations"
        }
        if AudioMuxAlignment.lead(audioDuration: 10, videoDuration: 8, hintedLead: 3) != 1.94 {
            return "mux lead must ignore an implausible clock hint"
        }
        if CaptureFinalizer.outcome(temporaryFile: nil, kind: .recording) != .cancelled {
            return "nil recording should cancel"
        }
        if PermissionPolicy.supportsOnScreenAudio(OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 7)) {
            return "macOS 13 should not advertise on-screen audio"
        }
        if !PermissionPolicy.supportsOnScreenAudio(OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)) {
            return "macOS 14.2 should support on-screen audio"
        }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("CapturePoint-SelfTest-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileDestination.ensureFolder(scratch, fileManager: fm)
            let historyURL = scratch.appendingPathComponent("history.json")
            var archive = HistoryArchive(fileURL: historyURL)
            let shot = scratch.appendingPathComponent("shot.png")
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: shot)
            try archive.add(url: shot, fileManager: fm)
            let reloaded = HistoryArchive.load(from: historyURL, fileManager: fm)
            if reloaded.shots.count != 1 || reloaded.shots[0].path != shot.path {
                try? fm.removeItem(at: scratch)
                return "history persist/reload"
            }
            try Data("not-json".utf8).write(to: historyURL)
            let corrupt = HistoryArchive.load(from: historyURL, fileManager: fm)
            if corrupt.lastLoadError == nil {
                try? fm.removeItem(at: scratch)
                return "corrupt history should report an error"
            }
            var blocked = corrupt
            do {
                try blocked.add(url: shot, fileManager: fm)
                try? fm.removeItem(at: scratch)
                return "corrupt history should block writes"
            } catch {
                // expected
            }
            if (try? String(contentsOf: historyURL, encoding: .utf8)) != "not-json" {
                try? fm.removeItem(at: scratch)
                return "corrupt history must not be overwritten"
            }
            try blocked.clear(fileManager: fm)
            if blocked.lastLoadError != nil {
                try? fm.removeItem(at: scratch)
                return "clear should recover history"
            }

            let tiny = scratch.appendingPathComponent("tiny.mov")
            try Data([0x00]).write(to: tiny)
            if CaptureFinalizer.outcome(temporaryFile: tiny, kind: .recording, fileManager: fm) != .cancelled {
                try? fm.removeItem(at: scratch)
                return "tiny recording should cancel"
            }
            let existing = try FilenameGenerator.filenames(in: scratch, fileManager: fm)
            let dest = CaptureFinalizer.suggestedDestination(
                folder: scratch,
                existingFilenames: existing.union(["Recording 2026-08-16 at 14.32.05.mov"]),
                kind: .recording,
                now: date,
                timeZone: tz
            )
            if dest.lastPathComponent != "Recording 2026-08-16 at 14.32.05 (2).mov" {
                try? fm.removeItem(at: scratch)
                return "collision destination: \(dest.lastPathComponent)"
            }
            try? fm.removeItem(at: scratch)
        } catch {
            try? fm.removeItem(at: scratch)
            return "self-test file ops: \(error.localizedDescription)"
        }

        return nil
    }
}
