import AppKit
import Carbon
import Foundation
import CapturePointCore

enum HotKeyAction: UInt32, CaseIterable {
    case selection = 1
    case window = 2
    case fullScreen = 3
    case recordToggle = 4

    var mode: CaptureMode? {
        switch self {
        case .selection: return .selection
        case .window: return .window
        case .fullScreen: return .fullScreen
        case .recordToggle: return nil
        }
    }

    var title: String {
        switch self {
        case .selection: return "Capture Selection"
        case .window: return "Capture Window"
        case .fullScreen: return "Capture Full Screen"
        case .recordToggle: return "Start/Stop Recording"
        }
    }

    var displayShortcut: String {
        switch self {
        case .selection: return "⌃⌘4"
        case .window: return "⌃⌘5"
        case .fullScreen: return "⌃⌘3"
        case .recordToggle: return "⌃⌘R"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .selection: return 21 // 4
        case .window: return 23    // 5
        case .fullScreen: return 20 // 3
        case .recordToggle: return 15 // R
        }
    }
}

@MainActor
final class HotKeyService {
    static let shared = HotKeyService()

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?
    private var onFire: ((HotKeyAction) -> Void)?
    private let signature = OSType(0x5350484B) // 'SPHK'

    private init() {}

    func update(enabled: Bool, onFire: @escaping (HotKeyAction) -> Void) {
        self.onFire = onFire
        unregister()
        guard enabled else { return }
        installHandler()
        for action in HotKeyAction.allCases {
            register(action)
        }
    }

    func unregister() {
        for ref in hotKeyRefs {
            if let ref {
                UnregisterEventHotKey(ref)
            }
        }
        hotKeyRefs.removeAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData, let event else { return noErr }
                var hkID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                guard status == noErr else { return noErr }
                let signature = hkID.signature
                let hotKeyID = hkID.id
                // The Carbon callback is not on the main actor. Touch the service there only.
                DispatchQueue.main.async {
                    let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
                    if signature == service.signature,
                       let action = HotKeyAction(rawValue: hotKeyID) {
                        service.onFire?(action)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )
    }

    private func register(_ action: HotKeyAction) {
        let id = EventHotKeyID(signature: signature, id: action.rawValue)
        var ref: EventHotKeyRef?
        let modifiers = UInt32(cmdKey | controlKey)
        let status = RegisterEventHotKey(
            action.keyCode,
            modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRefs.append(ref)
        } else {
            NSLog("CapturePoint: failed to register hotkey \(action.title) (status \(status))")
        }
    }
}
