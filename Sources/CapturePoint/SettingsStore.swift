import AppKit
import Combine
import Foundation
import CapturePointCore

@MainActor
final class SettingsStore: ObservableObject {
    @Published var saveFolder: URL {
        didSet { persistFolder() }
    }
    @Published var saveBehavior: SaveBehavior {
        didSet { defaults.set(saveBehavior.rawValue, forKey: Keys.saveBehavior) }
    }
    @Published var format: ImageFormat {
        didSet { defaults.set(format.rawValue, forKey: Keys.format) }
    }
    @Published var hideApp: Bool {
        didSet { defaults.set(hideApp, forKey: Keys.hideApp) }
    }
    @Published var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: Keys.copyToClipboard) }
    }
    @Published var includeCursor: Bool {
        didSet { defaults.set(includeCursor, forKey: Keys.includeCursor) }
    }
    @Published var playSound: Bool {
        didSet { defaults.set(playSound, forKey: Keys.playSound) }
    }
    @Published var delaySeconds: Int {
        didSet { defaults.set(delaySeconds, forKey: Keys.delaySeconds) }
    }
    @Published var showMenuBar: Bool {
        didSet { defaults.set(showMenuBar, forKey: Keys.showMenuBar) }
    }
    @Published var globalHotkeysEnabled: Bool {
        didSet { defaults.set(globalHotkeysEnabled, forKey: Keys.globalHotkeys) }
    }
    @Published var recentFolders: [URL] {
        didSet { persistRecentFolders() }
    }
    @Published var recordSystemAudio: Bool {
        didSet { defaults.set(recordSystemAudio, forKey: Keys.recordSystemAudio) }
    }
    @Published var recordMicrophone: Bool {
        didSet { defaults.set(recordMicrophone, forKey: Keys.recordMicrophone) }
    }
    @Published var showClicks: Bool {
        didSet { defaults.set(showClicks, forKey: Keys.showClicks) }
    }
    @Published var recordLimitSeconds: Int {
        didSet { defaults.set(recordLimitSeconds, forKey: Keys.recordLimit) }
    }
    @Published var captureAction: CaptureAction {
        didSet { defaults.set(captureAction.rawValue, forKey: Keys.captureAction) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let folderPath = "capturepoint.folderPath"
        static let folderBookmark = "capturepoint.folderBookmark"
        static let saveBehavior = "capturepoint.saveBehavior"
        static let format = "capturepoint.format"
        static let hideApp = "capturepoint.hideApp"
        static let copyToClipboard = "capturepoint.copyToClipboard"
        static let includeCursor = "capturepoint.includeCursor"
        static let playSound = "capturepoint.playSound"
        static let delaySeconds = "capturepoint.delaySeconds"
        static let showMenuBar = "capturepoint.showMenuBar"
        static let globalHotkeys = "capturepoint.globalHotkeys"
        static let recentFolders = "capturepoint.recentFolders"
        static let recordSystemAudio = "capturepoint.recordSystemAudio"
        static let recordMicrophone = "capturepoint.recordMicrophone"
        static let showClicks = "capturepoint.showClicks"
        static let recordLimit = "capturepoint.recordLimit"
        static let captureAction = "capturepoint.captureAction"
    }

    init() {
        Self.migrateLegacyDefaults(defaults)
        let folder = Self.resolveSavedFolder(defaults: defaults)
        saveFolder = folder

        if let raw = defaults.string(forKey: Keys.saveBehavior),
           let behavior = SaveBehavior(rawValue: raw) {
            saveBehavior = behavior
        } else {
            saveBehavior = .folder
        }

        if let raw = defaults.string(forKey: Keys.format),
           let format = ImageFormat(rawValue: raw) {
            self.format = format
        } else {
            format = .png
        }

        hideApp = defaults.object(forKey: Keys.hideApp) as? Bool ?? true
        copyToClipboard = defaults.object(forKey: Keys.copyToClipboard) as? Bool ?? true
        includeCursor = defaults.bool(forKey: Keys.includeCursor)
        playSound = defaults.object(forKey: Keys.playSound) as? Bool ?? true
        delaySeconds = defaults.object(forKey: Keys.delaySeconds) as? Int ?? 0
        showMenuBar = defaults.object(forKey: Keys.showMenuBar) as? Bool ?? true
        globalHotkeysEnabled = defaults.bool(forKey: Keys.globalHotkeys)

        if defaults.object(forKey: Keys.recordSystemAudio) == nil {
            recordSystemAudio = true
        } else {
            recordSystemAudio = defaults.bool(forKey: Keys.recordSystemAudio)
        }
        recordMicrophone = defaults.bool(forKey: Keys.recordMicrophone)
        showClicks = defaults.bool(forKey: Keys.showClicks)
        recordLimitSeconds = defaults.object(forKey: Keys.recordLimit) as? Int ?? 0

        if let raw = defaults.string(forKey: Keys.captureAction),
           let action = CaptureAction(rawValue: raw) {
            captureAction = action
        } else {
            captureAction = .screenshot
        }

        if let paths = defaults.stringArray(forKey: Keys.recentFolders) {
            recentFolders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        } else {
            recentFolders = []
        }

        rememberFolder(folder)
        persistFolder()
        // didSet does not run during init, so the recent list would stay unwritten.
        persistRecentFolders()
    }

    var delayOption: DelayOption {
        get { DelayOption(rawValue: delaySeconds) ?? .none }
        set { delaySeconds = newValue.rawValue }
    }

    var recordLimit: RecordLimit {
        get { RecordLimit(rawValue: recordLimitSeconds) ?? .untilStopped }
        set { recordLimitSeconds = newValue.rawValue }
    }

    func chooseSaveFolder() throws {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveFolder
        panel.prompt = "Choose"
        panel.message = "Choose where CapturePoint saves screenshots and recordings"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try setSaveFolder(url)
    }

    func setSaveFolder(_ url: URL) throws {
        try FileDestination.ensureFolder(url)
        saveFolder = url.standardizedFileURL
        rememberFolder(saveFolder)
    }

    func applyPreset(_ preset: FolderPreset) throws {
        try setSaveFolder(preset.url())
    }

    func openSaveFolder() throws {
        try FileDestination.ensureFolder(saveFolder)
        NSWorkspace.shared.open(saveFolder)
    }

    func rememberFolder(_ url: URL) {
        let standardized = url.standardizedFileURL
        var next = recentFolders.filter { $0.standardizedFileURL != standardized }
        next.insert(standardized, at: 0)
        if next.count > 8 {
            next = Array(next.prefix(8))
        }
        if next != recentFolders {
            recentFolders = next
        }
    }

    private func persistFolder() {
        defaults.set(saveFolder.path, forKey: Keys.folderPath)
        let data = try? saveFolder.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: Keys.folderBookmark)
    }

    private func persistRecentFolders() {
        defaults.set(recentFolders.map(\.path), forKey: Keys.recentFolders)
    }

    private static func migrateLegacyDefaults(_ defaults: UserDefaults) {
        let pairs = [
            ("snappath.folderPath", Keys.folderPath),
            ("snappath.folderBookmark", Keys.folderBookmark),
            ("snappath.saveBehavior", Keys.saveBehavior),
            ("snappath.format", Keys.format),
            ("snappath.hideApp", Keys.hideApp),
            ("snappath.copyToClipboard", Keys.copyToClipboard),
            ("snappath.includeCursor", Keys.includeCursor),
            ("snappath.playSound", Keys.playSound),
            ("snappath.delaySeconds", Keys.delaySeconds),
            ("snappath.showMenuBar", Keys.showMenuBar),
            ("snappath.globalHotkeys", Keys.globalHotkeys),
            ("snappath.recentFolders", Keys.recentFolders),
            ("snappath.recordSystemAudio", Keys.recordSystemAudio),
            ("snappath.recordMicrophone", Keys.recordMicrophone),
            ("snappath.showClicks", Keys.showClicks),
            ("snappath.recordLimit", Keys.recordLimit),
            ("snappath.captureAction", Keys.captureAction),
        ]
        for (old, new) in pairs {
            if defaults.object(forKey: new) == nil, let value = defaults.object(forKey: old) {
                defaults.set(value, forKey: new)
            }
        }
    }

    private static func resolveSavedFolder(defaults: UserDefaults) -> URL {
        if let data = defaults.data(forKey: Keys.folderBookmark) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url.standardizedFileURL
            }
        }
        if let path = defaults.string(forKey: Keys.folderPath) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultFolder()
    }

    static func defaultFolder() -> URL {
        let screenshots = FolderPreset.screenshots.url()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: screenshots.path, isDirectory: &isDir), isDir.boolValue {
            return screenshots
        }
        return FolderPreset.desktop.url()
    }
}
