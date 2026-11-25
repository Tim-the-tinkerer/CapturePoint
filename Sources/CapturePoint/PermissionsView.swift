import CapturePointCore
import SwiftUI

struct PermissionsPopover: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.headline)
            Text("Each feature has its own macOS permission. CapturePoint never treats Screen Recording as covering audio.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            row(.screenRecording, model.permissions.screenRecording)
            row(.audioCapture, model.permissions.audioCapture)
            row(.microphone, model.permissions.microphone)
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { model.refreshPermissions() }
    }

    private func row(_ kind: AppPermission, _ state: PermissionState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(dotColor(state))
                    .frame(width: 7, height: 7)
                Text(kind.title)
                    .font(.body.weight(.semibold))
                Spacer()
                Text(state.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(detail(kind, state))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle(kind, state)) {
                model.requestPermission(kind)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func dotColor(_ state: PermissionState) -> Color {
        switch state {
        case .granted: return .green
        case .unknown: return .secondary
        case .denied, .notDetermined, .unavailable: return .orange
        }
    }

    private func detail(_ kind: AppPermission, _ state: PermissionState) -> String {
        switch state {
        case .unavailable(let reason), .unknown(let reason):
            return reason
        default:
            return kind.summary
        }
    }

    private func actionTitle(_ kind: AppPermission, _ state: PermissionState) -> String {
        switch (kind, state) {
        case (_, .granted):
            return "Open Settings"
        case (.microphone, .notDetermined):
            return "Request Microphone"
        case (.screenRecording, _):
            return "Request Screen Recording"
        case (.audioCapture, .unavailable):
            return "Open Settings"
        default:
            return "Open Settings"
        }
    }
}
