import AppKit
import Combine
import SwiftUI

@main
struct SimplePasteMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Window-level state the SwiftUI view shares with the app delegate.
final class WidgetState: ObservableObject {
    @Published var showHistory: Bool
    init(showHistory: Bool) { self.showHistory = showHistory }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private static let frameName = "SimplePasteMonitor.widget"
    private static let frameKey = "widgetFrame"
    private static let soundKey = "arrivalSound"
    private static let historyKey = "showHistory"
    private static let minContentWidth: CGFloat = 180
    /// Sidebar plus its 1-pt divider.
    private static let sidebarSpace = ClipView.sidebarWidth + 1
    private static let defaultSize = NSSize(width: 280, height: 220)
    private static let privacySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!

    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var watcher: ClipboardWatcher!
    private let state = WidgetState(showHistory: UserDefaults.standard.bool(forKey: historyKey))

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
        // Borderless, resizable. Not titled with the title bar hidden: an
        // invisible title bar still owns its strip, and the controls in the
        // header — which lives there — never got a click.
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // ClipView picks its Theme from the color scheme this resolves to.
        panel.appearance = AppearanceSetting.current.nsAppearance
        // The rounded background is drawn by ClipView; the shadow follows it.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Dragging is done by WindowDragGesture in ClipView: on macOS 27 an
        // NSHostingView no longer offers its background for window moves.
        panel.isMovableByWindowBackground = false
        panel.contentMinSize = NSSize(width: minWidth(showingHistory: state.showHistory), height: 110)

        let host = NSHostingView(rootView: ClipView(
            watcher: watcher,
            state: state,
            toggleHistory: { [weak self] in self?.toggleHistory() },
            openPrivacySettings: { [weak self] in self?.openPrivacySettings() }
        ))
        host.sizingOptions = []   // the user sizes this window, not its content
        panel.contentView = host

        // Position and size come back from the last run — unless that spot is
        // gone (a display unplugged since), which would leave it off-screen.
        if let saved = savedFrame(), isOnScreen(saved) {
            panel.setFrame(saved, display: false)
        } else {
            placeAtDefault(panel)
        }
        // Saved now, not at the first move: otherwise a widget never touched
        // would be re-placed somewhere else next launch. (The window itself is
        // passed: `self.panel` isn't assigned until this method returns.)
        saveFrame(of: panel)
        panel.delegate = self
        return panel
    }

    // The frame is kept by hand, not with setFrameAutosaveName: AppKit
    // matches the saved display by its *visible* frame, which on a second
    // monitor changes whenever the Dock moves there. No match reads as "that
    // display is gone", and the widget got moved to the main display and
    // re-saved there — seen with a widget left on the lower of two monitors.
    // Here the frame is restored as it was whenever it is still on a screen.

    private func savedFrame() -> NSRect? {
        if let string = UserDefaults.standard.string(forKey: Self.frameKey) {
            let frame = NSRectFromString(string)
            return frame.width > 0 && frame.height > 0 ? frame : nil
        }
        // 1.0–1.1 kept it under AppKit's autosave key: "x y w h <screen>".
        let legacy = UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameName)")?
            .split(separator: " ").prefix(4).compactMap { Double($0) }
        guard let legacy, legacy.count == 4, legacy[2] > 0, legacy[3] > 0 else { return nil }
        return NSRect(x: legacy[0], y: legacy[1], width: legacy[2], height: legacy[3])
    }

    private func saveFrame(of window: NSWindow) {
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
    }

    func windowDidMove(_ notification: Notification) {
        (notification.object as? NSWindow).map(saveFrame(of:))
    }

    func windowDidResize(_ notification: Notification) {
        (notification.object as? NSWindow).map(saveFrame(of:))
    }

    private func isOnScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame.insetBy(dx: 40, dy: 40)) }
    }

    private func minWidth(showingHistory: Bool) -> CGFloat {
        Self.minContentWidth + (showingHistory ? Self.sidebarSpace : 0)
    }

    /// On the display under the mouse pointer, which is where the user is
    /// looking. Not NSScreen.main: that is the display with keyboard focus,
    /// it moves with whatever was clicked last, and with two monitors a
    /// first launch could put the widget on the one nobody was watching —
    /// seen in testing, the same fresh launch landed on a different display
    /// two runs in a row. It also makes Reset Widget Position bring the
    /// widget to the display whose menu bar was clicked.
    private func placeAtDefault(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        var size = Self.defaultSize
        if state.showHistory { size.width += Self.sidebarSpace }
        // Top-right: bottom-right is where Simple Claude Monitor lives.
        let origin = NSPoint(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }


    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "list.clipboard",
                                           accessibilityDescription: "Paste Monitor")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("Show Widget", #selector(toggleWidget)))
        menu.addItem(item("Show History", #selector(toggleHistory)))
        let sound = NSMenuItem(title: "Sound on Arrival", action: nil, keyEquivalent: "")
        sound.submenu = soundMenu()
        menu.addItem(sound)
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearance.submenu = appearanceMenu()
        menu.addItem(appearance)
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

    private func appearanceMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for setting in AppearanceSetting.allCases {
            let entry = item(setting.title, #selector(selectAppearance(_:)))
            entry.representedObject = setting.rawValue
            menu.addItem(entry)
            if setting == .system { menu.addItem(.separator()) }
        }
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let current = UserDefaults.standard.string(forKey: Self.soundKey) ?? ""
        for item in menu.items {
            switch item.action {
            case #selector(selectAppearance(_:)):
                item.state = (item.representedObject as? String) == AppearanceSetting.current.rawValue ? .on : .off
            case #selector(toggleWidget):
                item.state = panel.isVisible ? .on : .off
            case #selector(toggleHistory):
                item.state = state.showHistory ? .on : .off
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

    /// The sidebar opens to the left and the window grows by its width, so
    /// the clipboard you were watching stays exactly where it was.
    @objc private func toggleHistory() {
        let show = !state.showHistory
        var frame = panel.frame
        let delta = show ? Self.sidebarSpace : -Self.sidebarSpace
        frame.origin.x -= delta
        frame.size.width += delta
        // No room on the left: grow to the right instead.
        if let visible = panel.screen?.visibleFrame, frame.minX < visible.minX {
            frame.origin.x = visible.minX
        }
        panel.contentMinSize.width = minWidth(showingHistory: show)
        state.showHistory = show
        panel.setFrame(frame, display: true)
        UserDefaults.standard.set(show, forKey: Self.historyKey)
        panel.orderFrontRegardless()
    }

    @objc private func resetPosition() {
        placeAtDefault(panel)
        panel.orderFrontRegardless()
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let setting = AppearanceSetting(rawValue: raw) else { return }
        UserDefaults.standard.set(raw, forKey: AppearanceSetting.key)
        panel.appearance = setting.nsAppearance
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
