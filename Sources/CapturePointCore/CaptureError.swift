import Foundation

public enum CaptureError: LocalizedError, Equatable {
    case cancelled
    case failed(Int32, String)
    case missingTool
    case unwritable(URL)
    case folderCreateFailed(URL, String)
    case folderUnreadable(URL, String)
    case saveCancelled
    case saveFailed(String)
    case permissionDenied
    case recordingFailed(String)
    case trashFailed(String)
    case historyWriteFailed(String)
    case historyUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Capture cancelled"
        case .failed(let status, let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "screencapture exited with status \(status)"
            }
            return "screencapture exited with status \(status): \(trimmed)"
        case .missingTool:
            return "The system screencapture tool was not found"
        case .unwritable(let url):
            return "Cannot write to \(url.path)"
        case .folderCreateFailed(let url, let reason):
            return "Could not create folder \(url.path): \(reason)"
        case .folderUnreadable(let url, let reason):
            return "Could not read folder \(url.path): \(reason)"
        case .saveCancelled:
            return "Save cancelled — file not written"
        case .saveFailed(let message):
            return message
        case .permissionDenied:
            return "Screen Recording permission is required. Enable it in System Settings → Privacy & Security → Screen Recording."
        case .recordingFailed(let message):
            return message
        case .trashFailed(let message):
            return message
        case .historyWriteFailed(let message):
            return message
        case .historyUnreadable(let message):
            return message
        }
    }
}
