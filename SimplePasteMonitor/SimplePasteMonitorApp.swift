import AppKit
import SwiftUI

@main
struct SimplePasteMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private static let frameName = "SimplePasteMonitor.widget"
    private static let soundKey = "arrivalSound"
    private static let defaultSize = NSSize(width: 280, height: 220)
    private static let privacySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!

    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var watcher: ClipboardWatcher!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.register(defaults: [Self.soundKey: "Tink"])

        // A named pasteboard in place of the system one, for exercising the
        // app without touching what the user has copied — and without the
        // privacy prompt, which guards only the general pasteboard.
        let pasteboard = ProcessInfo.processInfo.environment["SPM_PASTEBOARD"]
            .map { NSPasteboard(name: NSPasteboard.Name($0)) } ?? .general
        watcher = ClipboardWatcher(pasteboard: pasteboard)
        watcher.onArrival = { [weak self] in self?.playArrivalSound() }

        panel = makePanel()
        panel.orderFrontRegardless()
        setUpStatusItem()
        watcher.start()
    }

    // MARK: - Widget window

    private func makePanel() -> NSPanel {
        // Titled, so the system gives it edge resizing, rounded corners and a
        // matching shadow — then every visible trace of the title bar is
        // taken away.
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = NSColor(white: 0.12, alpha: 0.92)
        panel.hasShadow = true
        // Dragging is done by WindowDragGesture in ClipView: on macOS 27 an
        // NSHostingView no longer offers its background for window moves.
        panel.isMovableByWindowBackground = false
        panel.contentMinSize = NSSize(width: 180, height: 110)
        panel.delegate = self

        let host = NSHostingView(rootView: ClipView(watcher: watcher) { [weak self] in
            self?.openPrivacySettings()
        })
        host.sizingOptions = []   // the user sizes this window, not its content
        panel.contentView = host

        // Position and size come back from the last run — unless that spot is
        // gone (a display unplugged since), which would leave it off-screen.
        if !panel.setFrameUsingName(Self.frameName) || !isOnScreen(panel.frame) {
            placeAtDefault(panel)
        }
        panel.setFrameAutosaveName(Self.frameName)
        // Saved now, not at the first move: otherwise a widget never touched
        // would be re-placed on whichever display is "main" next launch.
        panel.saveFrame(usingName: Self.frameName)
        return panel
    }

    private func isOnScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame.insetBy(dx: 40, dy: 40)) }
    }

    private func placeAtDefault(_ window: NSWindow) {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let size = Self.defaultSize
        // Top-right: bottom-right is where Simple Claude Monitor lives.
        let origin = NSPoint(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// A double-click on the (invisible) title bar would zoom the widget to
    /// fill the screen.
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { false }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "list.clipboard",
                                           accessibilityDescription: "Paste Monitor")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("Show Widget", #selector(toggleWidget)))
        let sound = NSMenuItem(title: "Sound on Arrival", action: nil, keyEquivalent: "")
        sound.submenu = soundMenu()
        menu.addItem(sound)
        menu.addItem(item("Reset Widget Position", #selector(resetPosition)))
        menu.addItem(.separator())
        menu.addItem(item("Clipboard Privacy Settings…", #selector(openPrivacySettings)))
        menu.addItem(item("About Simple Paste Monitor", #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func soundMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let none = item("None", #selector(selectSound(_:)))
        none.representedObject = ""
        menu.addItem(none)
        menu.addItem(.separator())
        // Whatever this macOS ships, rather than a list that goes stale.
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? [])
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
        for name in names {
            let entry = item(name, #selector(selectSound(_:)))
            entry.representedObject = name
            menu.addItem(entry)
        }
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let current = UserDefaults.standard.string(forKey: Self.soundKey) ?? ""
        for item in menu.items {
            switch item.action {
            case #selector(toggleWidget):
                item.state = panel.isVisible ? .on : .off
            case #selector(selectSound(_:)):
                item.state = (item.representedObject as? String) == current ? .on : .off
            default:
                break
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleWidget() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc private func resetPosition() {
        placeAtDefault(panel)
        panel.orderFrontRegardless()
    }

    @objc private func selectSound(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String ?? "", forKey: Self.soundKey)
        playArrivalSound()   // a preview of what was picked
    }

    private func playArrivalSound() {
        guard let name = UserDefaults.standard.string(forKey: Self.soundKey), !name.isEmpty,
              let sound = NSSound(named: NSSound.Name(name))
        else { return }
        sound.stop()   // two arrivals in a row: restart rather than skip
        sound.play()
    }

    @objc private func openPrivacySettings() {
        NSWorkspace.shared.open(Self.privacySettingsURL)
    }

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Simple Paste Monitor"
        alert.informativeText = """
            A floating window that shows what is on the clipboard — \
            image, text, files — as soon as it arrives, including from \
            iPhone and iPad over Universal Clipboard.

            v\(version)
            """
        alert.icon = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: nil)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
