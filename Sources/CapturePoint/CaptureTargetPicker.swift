import AppKit
import CoreGraphics
import CapturePointCore

enum CaptureTargetPicker {
    static func displayID(for mode: CaptureMode) -> CGDirectDisplayID {
        switch mode {
        case .mainDisplay:
            return CGMainDisplayID()
        case .fullScreen, .selection, .window:
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            if let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                return CGDirectDisplayID(number.uint32Value)
            }
            return CGMainDisplayID()
        }
    }

    static func pickRegion() async -> CGRect? {
        await OverlaySession.shared.pickRegion()
    }

    static func pickWindowID() async -> CGWindowID? {
        await OverlaySession.shared.pickWindow()
    }

    static func quartzPoint(from cocoa: NSPoint) -> CGPoint {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        let height = primary?.frame.height ?? 0
        return CGPoint(x: cocoa.x, y: height - cocoa.y)
    }

    static func sourceRect(appKitRect: CGRect, displayID: CGDirectDisplayID) -> CGRect {
        let screen = NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayID
        } ?? NSScreen.main
        let frame = screen?.frame ?? .zero
        let x = appKitRect.origin.x - frame.origin.x
        let yFromBottom = appKitRect.origin.y - frame.origin.y
        let yFromTop = frame.height - yFromBottom - appKitRect.height
        return CGRect(x: x, y: yFromTop, width: appKitRect.width, height: appKitRect.height)
    }

    static func quartzBounds(windowID: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let first = info.first,
              let bounds = first[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"],
              let w = bounds["Width"], let h = bounds["Height"]
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func displayID(containingQuartzRect rect: CGRect) -> CGDirectDisplayID {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var count: UInt32 = 8
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        if CGGetDisplaysWithPoint(center, 8, &ids, &count) == .success, count > 0 {
            return ids[0]
        }
        return CGMainDisplayID()
    }

    /// SCK `sourceRect` is in the display’s top-left point space.
    static func sourceRect(quartzRect: CGRect, displayID: CGDirectDisplayID) -> CGRect {
        let bounds = CGDisplayBounds(displayID)
        return CGRect(
            x: quartzRect.origin.x - bounds.origin.x,
            y: quartzRect.origin.y - bounds.origin.y,
            width: quartzRect.width,
            height: quartzRect.height
        )
    }

    static func backingScale(displayID: CGDirectDisplayID) -> CGFloat {
        let screen = NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayID
        }
        return screen?.backingScaleFactor ?? 2
    }
}

enum OverlayPick {
    case region(CGRect)
    case window(CGWindowID)
    case cancelled
}

enum OverlayMode {
    case region
    case window
}

@MainActor
private final class OverlaySession {
    static let shared = OverlaySession()

    private var overlays: [NSWindow] = []
    private var continuation: CheckedContinuation<OverlayPick, Never>?

    func pickRegion() async -> CGRect? {
        let result = await run(mode: .region)
        if case .region(let rect) = result { return rect }
        return nil
    }

    func pickWindow() async -> CGWindowID? {
        let result = await run(mode: .window)
        if case .window(let id) = result { return id }
        return nil
    }

    private func run(mode: OverlayMode) async -> OverlayPick {
        await withCheckedContinuation { continuation in
            let screens = NSScreen.screens
            guard !screens.isEmpty else {
                continuation.resume(returning: .cancelled)
                return
            }
            self.continuation = continuation
            for screen in screens {
                let view = OverlayView(mode: mode) { [weak self] result in
                    self?.finish(result)
                }
                let window = NSWindow(
                    contentRect: screen.frame,
                    styleMask: .borderless,
                    backing: .buffered,
                    defer: false,
                    screen: screen
                )
                window.isOpaque = false
                window.backgroundColor = .clear
                window.level = .screenSaver
                window.ignoresMouseEvents = false
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.contentView = view
                window.setFrame(screen.frame, display: true)
                window.makeKeyAndOrderFront(nil)
                overlays.append(window)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func finish(_ result: OverlayPick) {
        guard continuation != nil else { return }
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private final class OverlayView: NSView {
    private let mode: OverlayMode
    private let onFinish: (OverlayPick) -> Void
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var localMonitor: Any?
    private var finished = false

    init(mode: OverlayMode, onFinish: @escaping (OverlayPick) -> Void) {
        self.mode = mode
        self.onFinish = onFinish
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                self.handle(event)
                return nil
            }
        }
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let message = mode == .region
            ? "Drag to record an area · Esc to cancel"
            : "Click a window to record · Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (message as NSString).size(withAttributes: attrs)
        let box = CGRect(
            x: bounds.midX - size.width / 2 - 16,
            y: bounds.maxY - 64,
            width: size.width + 32,
            height: 34
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        (message as NSString).draw(
            at: NSPoint(x: box.minX + 16, y: box.minY + 8),
            withAttributes: attrs
        )

        if mode == .region, let start = dragStart, let current = dragCurrent {
            let rect = NSRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            NSColor.systemRed.withAlphaComponent(0.18).setFill()
            NSBezierPath(rect: rect).fill()
            NSColor.systemRed.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.stroke()
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 { finish(.cancelled) }
        case .leftMouseDown:
            if mode == .window {
                chooseWindow()
            } else {
                dragStart = convert(event.locationInWindow, from: nil)
                dragCurrent = dragStart
                needsDisplay = true
            }
        case .leftMouseDragged:
            guard mode == .region else { return }
            dragCurrent = convert(event.locationInWindow, from: nil)
            needsDisplay = true
        case .leftMouseUp:
            guard mode == .region, let start = dragStart, let current = dragCurrent else { return }
            let local = NSRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            guard local.width >= 8, local.height >= 8, let window else {
                finish(.cancelled)
                return
            }
            finish(.region(window.convertToScreen(local)))
        default:
            break
        }
    }

    private func chooseWindow() {
        let point = CaptureTargetPicker.quartzPoint(from: NSEvent.mouseLocation)
        let ourPID = ProcessInfo.processInfo.processIdentifier
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            finish(.cancelled)
            return
        }
        for win in info {
            let owner = win[kCGWindowOwnerPID as String] as? pid_t ?? 0
            if owner == ourPID { continue }
            let layer = win[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 { continue }
            guard
                let bounds = win[kCGWindowBounds as String] as? [String: CGFloat],
                let number = win[kCGWindowNumber as String] as? CGWindowID,
                let x = bounds["X"], let y = bounds["Y"],
                let w = bounds["Width"], let h = bounds["Height"]
            else { continue }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            if w < 80 || h < 80 { continue }
            if rect.contains(point) {
                finish(.window(number))
                return
            }
        }
        finish(.cancelled)
    }

    private func finish(_ result: OverlayPick) {
        guard !finished else { return }
        finished = true
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        onFinish(result)
    }
}
