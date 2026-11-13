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
    private var showsIcon = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = PanelController(store: NoteStore(folder: Prefs.folder, backups: Prefs.backups))
        controller.toggleSettings = { [weak self] in self?.settingsWindow.toggle() }
        controller.onScreenChange = { [weak self] in self?.settingsWindow.model.refreshPlace() }
        let model = settingsWindow.model
        model.describePlace = { [weak self] in self?.controller.defaultPlace() }
        model.useCurrentFrame = { [weak self] in self?.controller.useCurrentFrameAsDefault() }
        model.useStandardFrame = { [weak self] in self?.controller.useStandardFrame() }
        NSApp.mainMenu = mainMenu()
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

    /// Opening the app again while it runs, from Finder or Spotlight, opens Settings: the way back
    /// when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    /// Quitting never drops text silently: if the last changes can't be written, it asks.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.store.flush()
        guard controller.store.hasUnsavedChanges else { return .terminateNow }
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Your latest changes couldn’t be saved"
        alert.informativeText = "If you quit now, they will be lost. The footer of the note says why saving failed."
        alert.addButton(withTitle: "Don’t Quit")
        alert.addButton(withTitle: "Quit Anyway").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    // Any change to UserDefaults lands here, so each setting is applied only when it differs.
    private func applySettings() {
        registerHotKeys()
        let defaults = UserDefaults.standard
        controller.setFolder(Prefs.folder)
        controller.setOptions(
            fontFamily: defaults.string(forKey: "fontFamily") ?? "",
            fontSize: defaults.object(forKey: "fontSize") as? Double ?? Prefs.defaultFontSize,
            uiFontSize: defaults.object(forKey: "uiFontSize") as? Double ?? Prefs.defaultUIFontSize,
            showWhitespace: defaults.bool(forKey: "showWhitespace"),
            indentSize: defaults.object(forKey: "indentSize") as? Int ?? 4)
        controller.setNoteShortcuts(
            next: Prefs.shortcut("shortcut.nextNote"), previous: Prefs.shortcut("shortcut.previousNote"))
        controller.setBackgroundOpacity(
            defaults.object(forKey: "backgroundOpacity") as? Double ?? Prefs.defaultBackgroundOpacity)
        // Use Current and Reset change the defaults for ⌥⌘0, which Settings shows.
        settingsWindow.model.refreshPlace()
        // Compared with what was applied last, not with isVisible: setting isVisible saves it to
        // UserDefaults, which runs this again from inside the setter, maybe before isVisible changes.
        let showIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        if showIcon != showsIcon {
            showsIcon = showIcon
            statusItem.isVisible = showIcon
        }
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

    /// Never shown, since the app has no menu bar of its own, but it gives the settings window and
    /// the keys window quit, cut, copy, paste and close while the app is active, and ⌘, and ⇧⌘/,
    /// which open or close those windows as they do in the panel. Undo and Select All stay out: in the
    /// editor they must reach CodeMirror, not WebKit.
    private func mainMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let app = NSMenu(title: "notepanel")
        app.addItem(menuItem("Settings…", #selector(toggleSettings), ","))
        // "?" rather than "/" with Shift: a menu matches the character typed, and ⇧/ types "?". This is
        // how Help menus take ⇧⌘/.
        app.addItem(menuItem("Keyboard Shortcuts", #selector(toggleKeys), "?"))
        app.addItem(withTitle: "Quit notepanel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let menu = NSMenu()
        for submenu in [app, edit, window] {
            menu.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return menu
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
        // Each item shows the key that does the same in the panel.
        let menu = NSMenu()
        menu.addItem(menuItem("New Note", #selector(newNote), "n"))
        menu.addItem(menuItem("Search Notes", #selector(searchNotes), "p"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", #selector(openSettings), ","))
        // Shown as ⇧⌘/, as the docs write it. This menu only shows the key; the panel handles it.
        menu.addItem(menuItem("Keyboard Shortcuts", #selector(openKeys), "/", [.command, .shift]))
        menu.addItem(menuItem("Open Backups Folder", #selector(openBackups)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit notepanel", #selector(quit), "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func menuItem(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    @objc private func newNote() { controller.newNote() }
    @objc private func searchNotes() { controller.search() }
    @objc private func openSettings() { settingsWindow.show() }
    @objc private func openKeys() { KeysWindow.show() }
    @objc private func toggleSettings() { settingsWindow.toggle() }
    @objc private func toggleKeys() { KeysWindow.toggle() }
    @objc private func openBackups() {
        try? FileManager.default.createDirectory(at: Prefs.backups, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Prefs.backups)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
