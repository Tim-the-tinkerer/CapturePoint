import CapturePointCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show menu bar extra", isOn: $settings.showMenuBar)
                Toggle("Global hotkeys  ⌃⌘3  ⌃⌘4  ⌃⌘5  ⌃⌘R", isOn: $settings.globalHotkeysEnabled)
                    .help("Stills: full screen, selection, window. ⌃⌘R starts or stops a full-screen recording.")
                Toggle("Play shutter sound", isOn: $settings.playSound)
            }

            Section("Recording") {
                Picker("Limit", selection: Binding(
                    get: { settings.recordLimit },
                    set: { settings.recordLimit = $0 }
                )) {
                    ForEach(RecordLimit.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Toggle("Record microphone", isOn: $settings.recordMicrophone)
                    .onChange(of: settings.recordMicrophone) { enabled in
                        if enabled {
                            model.requestMicrophonePermission()
                        }
                        model.refreshPermissions()
                    }
                    .help("Optional second track of your voice. Does not capture on-screen audio.")
                Toggle("Highlight mouse clicks", isOn: $settings.showClicks)
                    .help("Window and selection recordings mark clicks on every supported macOS. Full-screen and main-display recordings mark clicks on macOS 15 and later.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { model.refreshPermissions() }
    }
}
