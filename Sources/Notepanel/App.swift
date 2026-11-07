import AppKit
import NotepanelCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // A menu bar app: no Dock icon and no main menu. Info.plist also sets LSUIElement.
        app.setActivationPolicy(.accessory)
        // `app.delegate` is weak, so keep the delegate alive for as long as the app runs.
        withExtendedLifetime(delegate) { app.run() }
    }

    private var controller: PanelController!
    private let hotKeys = HotKeys()
    private let settingsWindow = SettingsWindow()
    private var statusItem: NSStatusItem!
    private var registered: [Shortcut?] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = PanelController(store: NoteStore(folder: Prefs.folder))
        controller.openSettings = { [weak self] in self?.settingsWindow.show() }
        setUpStatusItem()
        applySettings()
        let center = NotificationCenter.default
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        center.addObserver(forName: .recordingShortcut, object: nil, queue: .main) { [weak self] notification in
            let recording = notification.object as? Bool == true
            MainActor.assumeIsolated {
                if recording { self?.hotKeys.set([]) } else { self?.registerHotKeys(force: true) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.store.flush()
    }

    // Any change to UserDefaults lands here, so each setting is applied only when it differs.
    private func applySettings() {
        registerHotKeys()
        let defaults = UserDefaults.standard
        controller.setFolder(Prefs.folder)
        controller.setOptions(
            fontFamily: defaults.string(forKey: "fontFamily") ?? "",
            fontSize: defaults.object(forKey: "fontSize") as? Double ?? 14,
            maxHeight: defaults.object(forKey: "maxHeight") as? Double ?? 640)
    }

    private func registerHotKeys(force: Bool = false) {
        let shortcuts = Prefs.hotKeyNames.map(Prefs.shortcut)
        guard force || shortcuts != registered else { return }
        registered = shortcuts
        let actions: [() -> Void] = [
            { [weak self] in self?.controller.toggle() },
            { [weak self] in self?.controller.newNote() },
            { [weak self] in self?.controller.search() },
        ]
        hotKeys.set(zip(shortcuts, actions).compactMap { shortcut, action in shortcut.map { ($0, action) } })
    }

    // MARK: - Menu bar icon

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "notepanel")
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// A click shows or hides the notes. A right-click, Control-click or Option-click opens the menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        guard event?.type == .rightMouseUp || flags.contains(.control) || flags.contains(.option) else {
            if controller.isVisible { controller.hide() } else { controller.show() }
            return
        }
        let menu = NSMenu()
        menu.addItem(menuItem("New Note", #selector(newNote)))
        menu.addItem(menuItem("Search Notes", #selector(searchNotes)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit notepanel", #selector(quit)))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func newNote() { controller.newNote() }
    @objc private func searchNotes() { controller.search() }
    @objc private func openSettings() { settingsWindow.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
