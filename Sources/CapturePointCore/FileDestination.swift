import Foundation

public enum FileDestination {
    public static func parentDirectory(of url: URL) -> URL? {
        let parent = url.deletingLastPathComponent()
        return parent.path.isEmpty ? nil : parent
    }

    public static func ensureFolder(_ url: URL, fileManager: FileManager = .default) throws {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw CaptureError.folderCreateFailed(url, "A file already exists at this path")
            }
        } else {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw CaptureError.folderCreateFailed(url, error.localizedDescription)
            }
        }
        guard fileManager.isWritableFile(atPath: url.path) else {
            throw CaptureError.unwritable(url)
        }
    }

    public static func moveReplacing(from: URL, to: URL, fileManager: FileManager = .default) throws {
        if let parent = parentDirectory(of: to) {
            try ensureFolder(parent, fileManager: fileManager)
        }
        if fileManager.fileExists(atPath: to.path) {
            // Replace only after the new file is in place, so a failed move
            // does not delete the previous capture.
            do {
                _ = try fileManager.replaceItemAt(to, withItemAt: from)
            } catch {
                throw CaptureError.saveFailed("Could not replace \(to.lastPathComponent): \(error.localizedDescription)")
            }
            return
        }
        do {
            try fileManager.moveItem(at: from, to: to)
        } catch {
            throw CaptureError.saveFailed("Could not save \(to.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
