import Foundation

public enum ImageFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case png
    case jpeg
    case tiff
    case pdf

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        case .pdf: return "PDF"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        case .pdf: return "pdf"
        }
    }

    /// Value passed to `screencapture -t`.
    public var screencaptureType: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        case .pdf: return "pdf"
        }
    }
}

public enum CaptureMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case selection
    case window
    case fullScreen
    case mainDisplay

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .selection: return "Selection"
        case .window: return "Window"
        case .fullScreen: return "Full Screen"
        case .mainDisplay: return "Main Display"
        }
    }

    public var symbolName: String {
        switch self {
        case .selection: return "plus.viewfinder"
        case .window: return "macwindow"
        case .fullScreen: return "rectangle.dashed"
        case .mainDisplay: return "display"
        }
    }

    public var helpText: String {
        switch self {
        case .selection: return "Drag a rectangle. Press Escape to cancel."
        case .window: return "Click a window. Space toggles selection mode. Escape cancels."
        case .fullScreen: return "Capture every display."
        case .mainDisplay: return "Capture the display with the menu bar."
        }
    }
}

public enum CaptureAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case screenshot
    case recording

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenshot: return "Screenshot"
        case .recording: return "Recording"
        }
    }
}

public enum SaveBehavior: String, CaseIterable, Identifiable, Codable, Sendable {
    case folder
    case askEachTime

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .folder: return "Save automatically to this folder"
        case .askEachTime: return "Ask where to save after each capture"
        }
    }

    public var shortTitle: String {
        switch self {
        case .folder: return "This folder"
        case .askEachTime: return "Ask each time"
        }
    }
}

public enum FolderPreset: String, CaseIterable, Identifiable, Sendable {
    case desktop
    case screenshots
    case pictures
    case downloads
    case documents

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .desktop: return "Desktop"
        case .screenshots: return "Screenshots"
        case .pictures: return "Pictures"
        case .downloads: return "Downloads"
        case .documents: return "Documents"
        }
    }

    public var symbolName: String {
        switch self {
        case .desktop: return "desktopcomputer"
        case .screenshots: return "camera.viewfinder"
        case .pictures: return "photo.on.rectangle"
        case .downloads: return "arrow.down.circle"
        case .documents: return "doc"
        }
    }

    /// `home` overrides the folder root for tests. The default uses the
    /// Finder locations, which follow a relocated Desktop or Pictures folder.
    public func url(home: URL? = nil) -> URL {
        let root = home ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if home == nil, let system = Self.systemDirectory(for: self) {
            return system
        }
        switch self {
        case .desktop:
            return root.appendingPathComponent("Desktop", isDirectory: true)
        case .screenshots:
            return root.appendingPathComponent("Pictures", isDirectory: true)
                .appendingPathComponent("Screenshots", isDirectory: true)
        case .pictures:
            return root.appendingPathComponent("Pictures", isDirectory: true)
        case .downloads:
            return root.appendingPathComponent("Downloads", isDirectory: true)
        case .documents:
            return root.appendingPathComponent("Documents", isDirectory: true)
        }
    }

    private static func systemDirectory(for preset: FolderPreset) -> URL? {
        let manager = FileManager.default
        switch preset {
        case .desktop:
            return manager.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .pictures:
            return manager.urls(for: .picturesDirectory, in: .userDomainMask).first
        case .screenshots:
            return manager.urls(for: .picturesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Screenshots", isDirectory: true)
        case .downloads:
            return manager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .documents:
            return manager.urls(for: .documentDirectory, in: .userDomainMask).first
        }
    }
}

public struct ShotRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var createdAt: Date
    public var byteCount: Int64

    public init(id: UUID = UUID(), path: String, createdAt: Date = Date(), byteCount: Int64) {
        self.id = id
        self.path = path
        self.createdAt = createdAt
        self.byteCount = byteCount
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }

    public var filename: String {
        url.lastPathComponent
    }

    public var isVideo: Bool {
        Self.isVideoPath(path)
    }

    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    public static func isVideoPath(_ path: String) -> Bool {
        videoExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}

public enum DelayOption: Int, CaseIterable, Identifiable, Sendable {
    case none = 0
    case three = 3
    case five = 5
    case ten = 10

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .none: return "None"
        case .three: return "3 seconds"
        case .five: return "5 seconds"
        case .ten: return "10 seconds"
        }
    }
}

public enum RecordLimit: Int, CaseIterable, Identifiable, Sendable {
    case untilStopped = 0
    case fifteen = 15
    case thirty = 30
    case sixty = 60
    case fiveMinutes = 300

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .untilStopped: return "Until stopped"
        case .fifteen: return "15 seconds"
        case .thirty: return "30 seconds"
        case .sixty: return "1 minute"
        case .fiveMinutes: return "5 minutes"
        }
    }
}
