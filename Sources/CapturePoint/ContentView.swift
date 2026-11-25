import AVFoundation
import AppKit
import CoreMedia
import CapturePointCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var history: HistoryStore
    @State private var isFolderDropTargeted = false
    @State private var showHelp = false
    @State private var showPermissions = false

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
        self.history = model.history
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            HSplitView {
                controls
                    .frame(minWidth: 360, idealWidth: 400)

                historyPane
                    .frame(minWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 720, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $isFolderDropTargeted, perform: handleFolderDrop)
        .overlay {
            if isFolderDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showHelp) {
            HelpSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .capturePointShowHelp)) { _ in
            showHelp = true
        }
        .onAppear { model.refreshPermissions() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.teal.gradient)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("CapturePoint")
                    .font(.title2.weight(.semibold))
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(model.statusMessage)
            }

            Spacer(minLength: 8)

            permissionBadge

            Button {
                NotificationCenter.default.post(name: .capturePointShowSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")

            Button {
                showHelp = true
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .help("CapturePoint Help")
        }
    }

    private var permissionBadge: some View {
        Button {
            showPermissions.toggle()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.permissions.needsAttention ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
                Text("Permissions")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        }
        .buttonStyle(.plain)
        .help("Screen Recording, Audio Capture, and Microphone")
        .popover(isPresented: $showPermissions) {
            PermissionsPopover(model: model)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                destinationSection
                actionSection
                detailsSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Destination")

            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.teal)
                    .symbolRenderingMode(.hierarchical)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.folderDisplay)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .help(settings.saveFolder.path)
                    Text(settings.saveFolder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button("Open") { model.openSaveFolder() }
                    .help("Reveal the save folder in Finder")
                Button("Choose…") { model.chooseSaveFolder() }
                    .help("Choose a different save folder")
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            HStack(spacing: 6) {
                ForEach(FolderPreset.allCases) { preset in
                    Button {
                        model.applyPreset(preset)
                    } label: {
                        Text(preset.title)
                    }
                    .controlSize(.small)
                    .help("Save to \(preset.title)")
                }
                Spacer(minLength: 0)
                if !settings.recentFolders.isEmpty {
                    Menu {
                        ForEach(settings.recentFolders, id: \.path) { url in
                            Button(PathDisplay.tildePath(url)) {
                                model.useSaveFolder(url)
                            }
                        }
                    } label: {
                        Text("Recent")
                    }
                    .controlSize(.small)
                }
            }

            Picker("Save behavior", selection: $settings.saveBehavior) {
                ForEach(SaveBehavior.allCases) { behavior in
                    Text(behavior.shortTitle).tag(behavior)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("This folder saves immediately. Ask each time opens a save dialog after capture.")
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Capture")

            if model.isRecording {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                    Text(PathDisplay.clock(model.recordingElapsed))
                        .font(.title3.monospacedDigit().weight(.semibold))
                    Text("Recording")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") {
                        model.stopRecording()
                    }
                    .keyboardShortcut(".", modifiers: [.command, .control])
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            } else {
                Picker("Action", selection: $settings.captureAction) {
                    ForEach(CaptureAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!model.canCapture)

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        targetButton(.selection)
                        targetButton(.window)
                    }
                    HStack(spacing: 8) {
                        targetButton(.fullScreen)
                        targetButton(.mainDisplay)
                    }
                }
            }
        }
    }

    private func targetButton(_ mode: CaptureMode) -> some View {
        let recording = settings.captureAction == .recording
        return Button {
            if recording {
                model.startRecording(mode)
            } else {
                model.capture(mode)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: mode.symbolName)
                        .frame(width: 18)
                    Text(mode.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if recording {
                        Image(systemName: "record.circle")
                            .foregroundStyle(.red)
                    }
                }
                Text(targetHelp(mode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        }
        .buttonStyle(TargetCardStyle())
        .disabled(recording ? !model.canRecord : !model.canCapture)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .help(targetHelp(mode))
    }

    private func targetHelp(_ mode: CaptureMode) -> String {
        if settings.captureAction == .recording {
            switch mode {
            case .selection: return "Drag a rectangle, then stop when you are done."
            case .window: return "Click a window. Works with browsers."
            case .fullScreen: return "Record every display as its own movie."
            case .mainDisplay: return "Record the display with the menu bar."
            }
        }
        return mode.helpText
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Details")
                Spacer()
                Button("More in Settings…") {
                    NotificationCenter.default.post(name: .capturePointShowSettings, object: nil)
                }
                .controlSize(.small)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                if settings.captureAction == .screenshot {
                    labeledPicker("Format") {
                        Picker("Format", selection: $settings.format) {
                            ForEach(ImageFormat.allCases) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                    }
                }
                labeledPicker("Delay") {
                    Picker("Delay", selection: Binding(
                        get: { settings.delayOption },
                        set: { settings.delayOption = $0 }
                    )) {
                        ForEach(DelayOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                }
            }

            Toggle("Hide CapturePoint before capture", isOn: $settings.hideApp)
            Toggle("Copy stills to clipboard", isOn: $settings.copyToClipboard)
            Toggle("Include pointer", isOn: $settings.includeCursor)
            if settings.captureAction == .recording || model.isRecording {
                Toggle("Include on-screen audio", isOn: $settings.recordSystemAudio)
                    .help("Sound of videos and apps. Needs Audio Capture on macOS 14.2+. Microphone is in Settings.")
                    .onChange(of: settings.recordSystemAudio) { _ in
                        model.refreshPermissions()
                    }
            }
        }
    }

    private func labeledPicker<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 140, alignment: .leading)
        }
    }

    // MARK: - History

    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionLabel("Recent")
                Spacer()
                if !history.shots.isEmpty {
                    Button("Clear list") {
                        do {
                            try history.clear()
                            model.selectedShotID = nil
                        } catch {
                            model.lastError = error.localizedDescription
                            model.statusMessage = error.localizedDescription
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                    .help("Remove items from the list without deleting files")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)
            // Keep the header above the preview so a scaled-to-fill image
            // cannot steal the Clear list click and open the file instead.
            .zIndex(1)

            if let shot = model.selectedShot {
                preview(for: shot)
                    .id(shot.id)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            if history.shots.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No screenshots yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Choose a folder, then capture or record.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(history.shots, id: \.id, selection: $model.selectedShotID) { shot in
                    historyRow(shot)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedShotID = shot.id }
                        .contextMenu { shotMenu(shot) }
                }
                .listStyle(.inset)
            }
        }
    }

    private func preview(for shot: ShotRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaPreview(url: shot.url, showPlayBadge: shot.isVideo)
                .id(shot.id)
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .clipped()
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .onTapGesture { model.open(shot) }

            HStack {
                Text(shot.filename)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(PathDisplay.byteCount(shot.byteCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(shot.isVideo ? "Play" : "Open") { model.open(shot) }
                Button("Reveal") { model.reveal(shot) }
                Button("Copy") { model.copy(shot) }
                Button("Trash", role: .destructive) { model.trash(shot) }
            }
            .controlSize(.small)
        }
    }

    private func historyRow(_ shot: ShotRecord) -> some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                MediaPreview(url: shot.url, showPlayBadge: false)
                    .id(shot.id)
                    .frame(width: 44, height: 30)
                    .clipped()
                    .contentShape(RoundedRectangle(cornerRadius: 4))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                if shot.isVideo {
                    Image(systemName: "video.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 2))
                        .padding(2)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(shot.filename)
                    .lineLimit(1)
                Text("\(PathDisplay.shortDate(shot.createdAt)) · \(PathDisplay.byteCount(shot.byteCount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func shotMenu(_ shot: ShotRecord) -> some View {
        Button("Open") { model.open(shot) }
        Button("Reveal in Finder") { model.reveal(shot) }
        Button(shot.isVideo ? "Copy File" : "Copy Image") { model.copy(shot) }
        Divider()
        Button("Move to Trash", role: .destructive) { model.trash(shot) }
        Button("Remove from List") {
            do {
                try model.history.remove(shot.id)
                if model.selectedShotID == shot.id {
                    model.selectedShotID = model.history.shots.first?.id
                }
            } catch {
                model.lastError = error.localizedDescription
                model.statusMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if model.isRecording {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("Recording \(PathDisplay.clock(model.recordingElapsed))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if model.isCapturing {
                ProgressView()
                    .controlSize(.small)
                Text("Capturing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(settings.saveBehavior == .askEachTime
                     ? "Ask where to save after each capture"
                     : "Saves to \(model.folderDisplay)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func handleFolderDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL? = {
                if let data = item as? Data {
                    return URL(dataRepresentation: data, relativeTo: nil)
                }
                if let url = item as? URL {
                    return url
                }
                return nil
            }()
            guard let url else { return }
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let folder = (exists && isDir.boolValue) ? url : url.deletingLastPathComponent()
            var folderIsDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &folderIsDir), folderIsDir.boolValue else {
                return
            }
            DispatchQueue.main.async {
                model.useSaveFolder(folder)
            }
        }
        return true
    }
}

private struct TargetCardStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: configuration.isPressed ? .selectedContentBackgroundColor : .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(configuration.isPressed ? 0.28 : 0.14), lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct MediaPreview: View {
    let url: URL
    var showPlayBadge: Bool = false
    @State private var image: NSImage?

    private var isVideo: Bool {
        ShotRecord.isVideoPath(url.path)
    }

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: isVideo ? "video" : "photo")
                    .foregroundStyle(.secondary)
            }
            if showPlayBadge {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 36))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .task(id: url.path) {
            if isVideo {
                let posterURL = url
                let cgImage = await Task.detached(priority: .utility) {
                    Self.videoPoster(url: posterURL)
                }.value
                image = cgImage.map { NSImage(cgImage: $0, size: .zero) }
            } else {
                image = NSImage(contentsOf: url)
            }
        }
    }

    nonisolated private static func videoPoster(url: URL) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 480)
        let time = CMTime(seconds: 0.15, preferredTimescale: 600)
        return try? generator.copyCGImage(at: time, actualTime: nil)
    }
}

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CapturePoint Help")
                .font(.title2.weight(.semibold))

            Text("CapturePoint captures screenshots and screen recordings with macOS’s own capture tool and writes the file where you choose.")
                .foregroundStyle(.secondary)

            Group {
                helpRow("Destination", "Choose the folder first. Presets and Recent jump to places you already use.")
                helpRow("Screenshot / Recording", "One choice, then the same four targets: selection, window, full screen, main display.")
                helpRow("Selection ⌃⌘4", "Drag a rectangle. Escape cancels.")
                helpRow("Window ⌃⌘5", "Click a window. Space toggles selection. Works with browsers.")
                helpRow("Full Screen ⌃⌘3", "Every display as its own file, or Main Display for the menu-bar screen only.")
                helpRow("Record", "Switch to Recording, pick a target. Full screen saves one movie per display, with sound in the first movie. Stop from the red bar, the menu bar, or ⌃⌘.")
                helpRow("⌃⌘R", "Start or stop a full-screen recording.")
                helpRow("On-screen audio", "On the Recording details row. Needs Audio Capture (macOS 14.2+).")
                helpRow("Highlight clicks", "In Settings. Window and selection recordings mark clicks. Full screen and main display mark clicks on macOS 15 and later.")
                helpRow("Settings ⌘,", "Menu bar, hotkeys, shutter sound, microphone, highlight clicks, and record limit.")
                helpRow("Recent", "Preview, open, reveal, copy, trash. Clearing the list does not delete files.")
                helpRow("Permissions", "Screen Recording, Audio Capture, and Microphone are listed separately.")
            }

            Text("macOS 13 can capture stills and picture-only recordings. On-screen audio uses a Core Audio process tap that exists only on macOS 14.2 and later.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func helpRow(_ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(width: 130, alignment: .leading)
            Text(body)
                .foregroundStyle(.secondary)
        }
    }
}

extension Notification.Name {
    static let capturePointShowHelp = Notification.Name("capturepoint.showHelp")
    static let capturePointShowSettings = Notification.Name("capturepoint.showSettings")
    static let capturePointChooseFolder = Notification.Name("capturepoint.chooseFolder")
    static let capturePointCapture = Notification.Name("capturepoint.capture")
}
