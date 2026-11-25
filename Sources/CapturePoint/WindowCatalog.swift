import AppKit
import CoreGraphics

struct CapturedWindow: Identifiable, Hashable {
    let id: CGWindowID
    let owner: String
    let title: String
    let bounds: CGRect

    var displayName: String {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return owner
        }
        return "\(owner) — \(title)"
    }
}

enum WindowCatalog {
    private static let skippedOwners: Set<String> = [
        "Window Server",
        "Dock",
        "Control Center",
        "Notification Centre",
        "Notification Center",
        "SystemUIServer",
        "Spotlight",
        "Screenshot",
        "screencaptureui",
        "Item-0",
        "CapturePoint",
        "SnapPath",
    ]

    static func list() -> [CapturedWindow] {
        let ourPID = ProcessInfo.processInfo.processIdentifier
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var seen = Set<CGWindowID>()
        var result: [CapturedWindow] = []
        for win in info {
            let ownerPID = win[kCGWindowOwnerPID as String] as? pid_t ?? 0
            if ownerPID == ourPID { continue }
            let layer = win[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 { continue }
            guard
                let number = win[kCGWindowNumber as String] as? CGWindowID,
                let bounds = win[kCGWindowBounds as String] as? [String: CGFloat],
                let x = bounds["X"], let y = bounds["Y"],
                let w = bounds["Width"], let h = bounds["Height"]
            else { continue }
            if seen.contains(number) { continue }
            if w < 160 || h < 120 { continue }
            let owner = (win[kCGWindowOwnerName as String] as? String) ?? ""
            if owner.isEmpty || skippedOwners.contains(owner) { continue }
            let title = (win[kCGWindowName as String] as? String) ?? ""
            seen.insert(number)
            result.append(
                CapturedWindow(
                    id: number,
                    owner: owner,
                    title: title,
                    bounds: CGRect(x: x, y: y, width: w, height: h)
                )
            )
        }
        return result.sorted {
            if $0.owner != $1.owner { return $0.owner.localizedCaseInsensitiveCompare($1.owner) == .orderedAscending }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
}
