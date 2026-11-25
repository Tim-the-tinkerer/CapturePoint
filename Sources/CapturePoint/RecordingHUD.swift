import AppKit
import CapturePointCore

@MainActor
final class RecordingHUD {
    private var panel: NSPanel?
    private var timeField: NSTextField?
    private var onStop: (() -> Void)?

    func show(onStop: @escaping () -> Void) {
        self.onStop = onStop
        if panel == nil {
            build()
        }
        updateElapsed(0)
        position()
        panel?.orderFrontRegardless()
    }

    func updateElapsed(_ interval: TimeInterval) {
        timeField?.stringValue = PathDisplay.clock(interval)
    }

    func close() {
        panel?.orderOut(nil)
        onStop = nil
    }

    private func build() {
        let width: CGFloat = 292
        let height: CGFloat = 54
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        container.layer?.cornerRadius = 12

        let dot = NSView(frame: NSRect(x: 16, y: 21, width: 12, height: 12))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 6
        container.addSubview(dot)

        let time = NSTextField(labelWithString: "0:00")
        time.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        time.textColor = .white
        time.alignment = .left
        time.frame = NSRect(x: 36, y: 16, width: 88, height: 22)
        container.addSubview(time)
        timeField = time

        let stop = NSButton(title: "Stop", target: self, action: #selector(stopTapped))
        stop.bezelStyle = .rounded
        stop.controlSize = .regular
        stop.keyEquivalent = "\r"
        stop.frame = NSRect(x: 196, y: 12, width: 80, height: 30)
        container.addSubview(stop)

        let panel = NSPanel(
            contentRect: container.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.contentView = container
        panel.ignoresMouseEvents = false
        self.panel = panel
    }

    private func position() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 12
        ))
    }

    @objc private func stopTapped() {
        onStop?()
    }
}
