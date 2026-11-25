import AppKit
import Foundation
import CapturePointCore

struct StillCaptureResult {
    var files: [URL]
    var warning: String?
}

enum CaptureService {
    static let toolPath = "/usr/sbin/screencapture"
    private static let processLock = NSLock()
    private static var activeProcess: Process?

    /// Ends an in-progress still capture so quit does not leave `screencapture` up.
    static func cancelActive() {
        processLock.lock()
        let process = activeProcess
        processLock.unlock()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    static var toolExists: Bool {
        FileManager.default.isExecutableFile(atPath: toolPath)
    }

    static func hasScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func run(
        mode: CaptureMode,
        destination: URL,
        format: ImageFormat,
        includeCursor: Bool,
        playSound: Bool,
        copyToClipboard: Bool
    ) throws -> StillCaptureResult {
        guard toolExists else { throw CaptureError.missingTool }

        // screencapture writes one file per path. A single path keeps only
        // the first display, so a full-screen still passes one path per screen.
        let outputs: [URL]
        if mode == .fullScreen {
            let count = max(1, NSScreen.screens.count)
            outputs = (1...count).map { CaptureLayout.url(destination, displayIndex: $0) }
        } else {
            outputs = [destination]
        }

        var args: [String] = []
        switch mode {
        case .selection:
            args.append(contentsOf: ["-i", "-s"])
        case .window:
            args.append(contentsOf: ["-i", "-w"])
        case .fullScreen:
            break
        case .mainDisplay:
            args.append("-m")
        }
        if includeCursor { args.append("-C") }
        if !playSound { args.append("-x") }
        // Do not pass -c. That flag forces clipboard-only output and
        // silently skips writing `destination` (exit status 0, no file).
        args.append("-t")
        args.append(format.screencaptureType)
        args.append(contentsOf: outputs.map(\.path))

        let (status, stderr) = try launch(args)
        var files: [URL] = []
        for url in outputs {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            if FileManager.default.fileExists(atPath: url.path), size > 0 {
                files.append(url)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        if files.isEmpty {
            if !hasScreenRecordingAccess() {
                throw CaptureError.permissionDenied
            }
            if status == 0 || status == 1 {
                throw CaptureError.cancelled
            }
            throw CaptureError.failed(status, stderr)
        }

        if copyToClipboard {
            _ = copyImageFilesToClipboard(files)
        }
        let warning = files.count < outputs.count
            ? "Captured \(files.count) of \(outputs.count) displays."
            : nil
        return StillCaptureResult(files: files, warning: warning)
    }

    /// Drains stderr on another thread so a chatty screencapture cannot fill
    /// the pipe and stall `waitUntilExit`.
    private static func launch(_ args: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe

        let reading = errPipe.fileHandleForReading
        let box = StderrBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = reading.readDataToEndOfFile()
            box.text = String(data: data, encoding: .utf8) ?? ""
            group.leave()
        }

        processLock.lock()
        activeProcess = process
        processLock.unlock()
        defer {
            processLock.lock()
            if activeProcess === process {
                activeProcess = nil
            }
            processLock.unlock()
        }

        do {
            try process.run()
        } catch {
            try? errPipe.fileHandleForWriting.close()
            group.wait()
            throw CaptureError.failed(-1, error.localizedDescription)
        }
        process.waitUntilExit()
        group.wait()
        return (process.terminationStatus, box.text)
    }

    static func copyImageFileToClipboard(_ url: URL) -> Bool {
        copyImageFilesToClipboard([url])
    }

    @discardableResult
    static func copyImageFilesToClipboard(_ urls: [URL]) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let images = urls.compactMap { NSImage(contentsOf: $0) }
        if !images.isEmpty, pasteboard.writeObjects(images) {
            return true
        }
        guard let url = urls.first, let data = try? Data(contentsOf: url) else { return false }
        let type: NSPasteboard.PasteboardType
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": type = NSPasteboard.PasteboardType("public.jpeg")
        case "tif", "tiff": type = NSPasteboard.PasteboardType("public.tiff")
        case "pdf": type = NSPasteboard.PasteboardType("com.adobe.pdf")
        default: type = .png
        }
        return pasteboard.setData(data, forType: type)
    }

    static func presentSavePanel(
        defaultDirectory: URL,
        suggestedName: String,
        message: String = "Choose where to save this screenshot"
    ) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = defaultDirectory
        panel.nameFieldStringValue = suggestedName
        panel.prompt = "Save"
        panel.message = message
        if panel.runModal() == .OK, let url = panel.url {
            return url
        }
        return nil
    }
}

private final class StderrBox: @unchecked Sendable {
    var text = ""
}

@MainActor
final class CountdownHUD {
    private var window: NSPanel?

    func run(seconds: Int, isCancelled: @MainActor () -> Bool = { false }) async {
        guard seconds > 0 else { return }

        let label = NSTextField(labelWithString: "\(seconds)")
        label.font = .monospacedDigitSystemFont(ofSize: 72, weight: .semibold)
        label.alignment = .center
        label.textColor = .white
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 168, height: 168))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.74).cgColor
        container.layer?.cornerRadius = 28
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        let panel = NSPanel(
            contentRect: container.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = container
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 84, y: frame.midY - 84))
        }
        panel.orderFrontRegardless()
        window = panel

        for n in stride(from: seconds, through: 1, by: -1) {
            if isCancelled() { break }
            label.stringValue = "\(n)"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        panel.orderOut(nil)
        window = nil
        if !isCancelled() {
            try? await Task.sleep(nanoseconds: 180_000_000)
        }
    }
}
