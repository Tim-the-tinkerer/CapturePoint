import AppKit
import Combine
import CapturePointCore
import SwiftUI

@main
struct MainEntry {
    static func main() {
        let args = CommandLine.arguments

        if args.contains("--self-test") {
            if let err = SelfTest.run() {
                fputs("SELF-TEST FAILED: \(err)\n", stderr)
                exit(1)
            }
            print("SELF-TEST OK")
            exit(0)
        }

        if args.contains("--help") || args.contains("-h") {
            print(helpText)
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    private static let helpText = """
    CapturePoint — capture screenshots and recordings, and choose where they are saved

    Usage:
      CapturePoint                 Launch the app
      CapturePoint --self-test     Run built-in checks
      CapturePoint --help          Show this help

    In the app:
      Choose a save folder, or turn on “Ask where to save after each capture”.
      Capture stills or start a screen recording (selection, window, full screen).
      Stop a recording from the red bar, the menu bar, or ⌃⌘.
      Optional global hotkeys: ⌃⌘3 full screen, ⌃⌘4 selection, ⌃⌘5 window, ⌃⌘R record.
    """
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    let model = AppModel()
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    private let minSize = NSSize(width: 720, height: 500)
    private let defaultSize = NSSize(width: 860, height: 560)

    private override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        showMainWindow()
        updateStatusItem()
        registerHotkeys()
        observeSettings()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettings(_:)),
            name: .capturePointShowSettings,
            object: nil
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.beginTermination()
        Task { @MainActor in
            await model.finishForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyService.shared.unregister()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.settings.showMenuBar
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Window

    func showMainWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = ContentView(model: model)
            .frame(minWidth: minSize.width, minHeight: minSize.height)

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: defaultSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CapturePoint"
        window.contentView = hosting
        window.setContentSize(defaultSize)
        window.contentMinSize = minSize
        window.isRestorable = true
        window.setFrameAutosaveName("CapturePointMain")
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    // MARK: - Status item

    private func observeSettings() {
        model.settings.$showMenuBar
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)

        model.settings.$globalHotkeysEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.registerHotkeys()
            }
            .store(in: &cancellables)

        model.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        if model.settings.showMenuBar {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                if let button = item.button {
                    button.image = NSImage(
                        systemSymbolName: model.isRecording ? "record.circle.fill" : "camera.viewfinder",
                        accessibilityDescription: "CapturePoint"
                    )
                    button.contentTintColor = model.isRecording ? .systemRed : nil
                    button.toolTip = model.isRecording ? "CapturePoint — recording" : "CapturePoint"
                }
                statusItem = item
            }
            if let button = statusItem?.button {
                button.image = NSImage(
                    systemSymbolName: model.isRecording ? "record.circle.fill" : "camera.viewfinder",
                    accessibilityDescription: "CapturePoint"
                )
                button.contentTintColor = model.isRecording ? .systemRed : nil
                button.toolTip = model.isRecording ? "CapturePoint — recording" : "CapturePoint"
            }
            statusItem?.menu = buildStatusMenu()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        if model.isRecording {
            menu.addItem(menuItem("Stop Recording", #selector(stopRecording(_:)), key: ".", modifiers: [.command, .control]))
            menu.addItem(.separator())
        }
        addCaptureItems(to: menu)
        menu.addItem(.separator())
        addRecordItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(menuItem("Choose Save Folder…", #selector(chooseFolder(_:))))
        menu.addItem(menuItem("Open Save Folder", #selector(openFolder(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", #selector(showSettings(_:)), key: ","))
        menu.addItem(menuItem("Show CapturePoint", #selector(showWindow(_:)), key: "n"))
        menu.addItem(menuItem("Quit CapturePoint", #selector(quit(_:)), key: "q"))
        return menu
    }

    private func addCaptureItems(to menu: NSMenu) {
        menu.addItem(menuItem(
            "Capture Selection",
            #selector(captureSelection(_:)),
            key: "4",
            modifiers: [.command, .control]
        ))
        menu.addItem(menuItem(
            "Capture Window",
            #selector(captureWindow(_:)),
            key: "5",
            modifiers: [.command, .control]
        ))
        menu.addItem(menuItem(
            "Capture Full Screen",
            #selector(captureFullScreen(_:)),
            key: "3",
            modifiers: [.command, .control]
        ))
        menu.addItem(menuItem(
            "Capture Main Display",
            #selector(captureMainDisplay(_:)),
            key: "3",
            modifiers: [.command, .control, .shift]
        ))
    }

    private func addRecordItems(to menu: NSMenu) {
        menu.addItem(menuItem("Record Selection", #selector(recordSelection(_:))))
        menu.addItem(menuItem("Record Window", #selector(recordWindow(_:))))
        menu.addItem(menuItem(
            "Record Full Screen",
            #selector(recordFullScreen(_:)),
            key: "r",
            modifiers: [.command, .control]
        ))
        menu.addItem(menuItem("Record Main Display", #selector(recordMainDisplay(_:))))
        if !model.isRecording {
            menu.addItem(menuItem(
                "Stop Recording",
                #selector(stopRecording(_:)),
                key: ".",
                modifiers: [.command, .control]
            ))
        }
    }

    private func menuItem(
        _ title: String,
        _ selector: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        if !key.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        item.target = self
        return item
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        HotKeyService.shared.update(enabled: model.settings.globalHotkeysEnabled) { [weak self] action in
            guard let self else { return }
            if action == .recordToggle {
                self.model.toggleRecording()
            } else if let mode = action.mode {
                self.model.capture(mode)
            }
        }
    }

    // MARK: - Actions

    @objc func showWindow(_ sender: Any?) {
        showMainWindow()
    }

    @objc func quit(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    @objc func chooseFolder(_ sender: Any?) {
        showMainWindow()
        model.chooseSaveFolder()
    }

    @objc func openFolder(_ sender: Any?) {
        model.openSaveFolder()
    }

    @objc func captureSelection(_ sender: Any?) {
        model.capture(.selection)
    }

    @objc func captureWindow(_ sender: Any?) {
        model.capture(.window)
    }

    @objc func captureFullScreen(_ sender: Any?) {
        model.capture(.fullScreen)
    }

    @objc func captureMainDisplay(_ sender: Any?) {
        model.capture(.mainDisplay)
    }

    @objc func recordSelection(_ sender: Any?) {
        model.startRecording(.selection)
    }

    @objc func recordWindow(_ sender: Any?) {
        model.startRecording(.window)
    }

    @objc func recordFullScreen(_ sender: Any?) {
        model.startRecording(.fullScreen)
    }

    @objc func recordMainDisplay(_ sender: Any?) {
        model.startRecording(.mainDisplay)
    }

    @objc func stopRecording(_ sender: Any?) {
        model.stopRecording()
    }

    @objc func showHelp(_ sender: Any?) {
        showMainWindow()
        NotificationCenter.default.post(name: .capturePointShowHelp, object: nil)
    }

    @objc func showSettings(_ sender: Any?) {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let size = NSSize(width: 440, height: 420)
        let root = SettingsView(model: model)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc func showAbout(_ sender: Any?) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.5.3"
        let build = info?["CFBundleVersion"] as? String ?? "4"
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "CapturePoint",
            .version: version,
            .applicationVersion: "Version \(version) (\(build))",
            .credits: NSAttributedString(
                string: "Capture screenshots and screen recordings, and choose exactly where they are saved.",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ),
        ]
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    // MARK: - Main menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About CapturePoint", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("Settings…", #selector(showSettings(_:)), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide CapturePoint", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit CapturePoint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(menuItem(
            "Choose Save Folder…",
            #selector(chooseFolder(_:)),
            key: "o",
            modifiers: [.command, .shift]
        ))
        fileMenu.addItem(menuItem(
            "Open Save Folder",
            #selector(openFolder(_:)),
            key: "o",
            modifiers: [.command, .option]
        ))
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let captureMenuItem = NSMenuItem()
        mainMenu.addItem(captureMenuItem)
        let captureMenu = NSMenu(title: "Capture")
        captureMenuItem.submenu = captureMenu
        addCaptureItems(to: captureMenu)

        let recordMenuItem = NSMenuItem()
        mainMenu.addItem(recordMenuItem)
        let recordMenu = NSMenu(title: "Record")
        recordMenuItem.submenu = recordMenu
        addRecordItems(to: recordMenu)

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(menuItem("Show CapturePoint", #selector(showWindow(_:)), key: "0"))
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        helpMenu.addItem(menuItem("CapturePoint Help", #selector(showHelp(_:)), key: "?"))
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(stopRecording(_:)):
            return model.isRecording
        case #selector(recordSelection(_:)),
             #selector(recordWindow(_:)),
             #selector(recordFullScreen(_:)),
             #selector(recordMainDisplay(_:)):
            return model.canRecord
        case #selector(captureSelection(_:)),
             #selector(captureWindow(_:)),
             #selector(captureFullScreen(_:)),
             #selector(captureMainDisplay(_:)):
            return model.canCapture
        default:
            return true
        }
    }
}
