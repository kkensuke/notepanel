import AppKit
import NotepanelCore

/// Shows and hides the note panel, and connects it to the note store and the editor page.
@MainActor
final class PanelController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    let store: NoteStore
    var openSettings: () -> Void = {}

    private let panel: NotePanel
    private let bridge = EditorBridge()
    private let titleLabel = NSTextField(labelWithString: "")
    private var buttons: [NSToolbarItem.Identifier: NSButton] = [:]
    private var previousApp: NSRunningApplication?
    private var contentHeight: CGFloat = 0
    private var uiScale: CGFloat = 1.5
    private var options: NSDictionary = [:]
    /// Old names of renamed notes, so text the page sent under an old name still lands.
    private var renamed: [String: String] = [:]

    private static let frameName = "Note Panel"
    private static let minHeight: CGFloat = 120
    /// The window grows with its note up to this share of the screen's height, then scrolls.
    private static let maxScreenShare: CGFloat = 2.0 / 3.0

    private enum Item {
        static let title = NSToolbarItem.Identifier("title")
        static let new = NSToolbarItem.Identifier("new")
        static let browse = NSToolbarItem.Identifier("browse")
        static let folder = NSToolbarItem.Identifier("folder")
    }

    init(store: NoteStore) {
        self.store = store
        panel = NotePanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()
        configurePanel()
        store.onStatus = { [weak self] message in self?.bridge.send("status", message ?? "") }
        store.onRenamed = { [weak self] from, to in self?.noteRenamed(from, to) }
        bridge.onMessage = { [weak self] type, body in self?.handle(type, body) }
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Showing and hiding

    func show() {
        if !panel.isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == NSRunningApplication.current.processIdentifier ? nil : front
            if let text = store.reloadIfChanged(), let name = store.current {
                bridge.send("open", ["id": name, "text": text, "keep": false])
            }
        }
        // shortcut: lets risk R1 be tried both ways; remove once M0 settles on one.
        if UserDefaults.standard.bool(forKey: "activateOnShow") { NSApp.activate() }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(bridge.webView)
        bridge.send("focus", "")
    }

    /// Returns focus to the app that was in front, unless the user has moved on to another one.
    func hide() {
        store.flush()
        guard panel.isVisible else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let movedOn = front != NSRunningApplication.current.processIdentifier && front != previousApp?.processIdentifier
        panel.orderOut(nil)
        if !movedOn { _ = previousApp?.activate(options: []) }
    }

    /// Hides the panel if it's in front, and otherwise brings it forward.
    func toggle() {
        if panel.isVisible && panel.isKeyWindow { hide() } else { show() }
    }

    func newNote() {
        createNote()
        show()
    }

    func search() {
        show()
        bridge.send("switcher", ["notes": notesForSwitcher(), "force": true])
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.folder)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    // MARK: - Settings

    func setFolder(_ folder: URL) {
        guard folder.standardizedFileURL != store.folder.standardizedFileURL else { return }
        store.setFolder(folder)
        UserDefaults.standard.removeObject(forKey: "lastNote")
        openSomeNote()
    }

    func setOptions(fontFamily: String, fontSize: Double, uiScale: Double) {
        let new: NSDictionary = ["fontFamily": fontFamily, "fontSize": fontSize, "uiScale": uiScale]
        guard new != options else { return }
        options = new
        bridge.send("options", new)
        if CGFloat(uiScale) != self.uiScale {
            self.uiScale = CGFloat(uiScale)
            applyScale()
        }
    }

    /// Cmd-plus and Cmd-minus step the note's text size; Cmd-0 sets it back to the default.
    /// It's the same setting as in the settings window.
    private func zoom(_ step: Int) {
        let defaults = UserDefaults.standard
        let size = defaults.object(forKey: "fontSize") as? Double ?? Prefs.defaultFontSize
        let new = step == 0 ? Prefs.defaultFontSize : size + Double(step)
        defaults.set(min(Prefs.fontSizes.upperBound, max(Prefs.fontSizes.lowerBound, new)), forKey: "fontSize")
    }

    // MARK: - Messages from the page

    private func handle(_ type: String, _ body: [String: Any]) {
        switch type {
        case "ready":
            // Also after the page reloads, so it gets its options and a note again.
            bridge.send("options", options)
            openSomeNote()
        case "changed":
            // The page sends the whole text, so text sent under a name the note just lost is
            // still the current note's text.
            guard let sent = body["id"] as? String, let current = store.current,
                sent == current || renamed[sent] == current,
                let text = body["text"] as? String
            else { return }
            store.edit(text)
        case "height":
            guard let height = body["height"] as? Double else { return }
            contentHeight = CGFloat(height)
            fitHeight()
        case "select":
            if let id = body["id"] as? String { open(id) }
        case "trash":
            if let id = body["id"] as? String { confirmTrash(id) }
        case "rename":
            guard let from = body["from"] as? String, let to = body["to"] as? String else { return }
            rename(from, to: to)
            bridge.send("notes", notesForSwitcher())
        case "openURL":
            // The page is trusted, but a link can say anything, so only web and mail links open.
            guard let string = body["url"] as? String, let url = URL(string: string),
                ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
            else { return }
            NSWorkspace.shared.open(url)
        case "escape":
            hide()
        default:
            break
        }
    }

    // MARK: - Notes

    @discardableResult
    private func open(_ name: String, keepSwitcher: Bool = false) -> Bool {
        guard let text = store.open(name) else { return false }
        bridge.send("open", ["id": name, "text": text, "keep": keepSwitcher])
        rememberCurrent()
        updateTitle()
        return true
    }

    /// Opens the last note, else the newest readable one, else a new one, so a note is always open.
    private func openSomeNote(keepSwitcher: Bool = false) {
        let names = store.list().map(\.name)
        var candidates = names
        if let last = UserDefaults.standard.string(forKey: "lastNote"), names.contains(last) {
            candidates.insert(last, at: 0)
        }
        for name in candidates {
            if open(name, keepSwitcher: keepSwitcher) { return }
        }
        createNote(keepSwitcher: keepSwitcher)
    }

    private func createNote(keepSwitcher: Bool = false) {
        do {
            let name = try store.create()
            bridge.send("open", ["id": name, "text": "", "keep": keepSwitcher])
            rememberCurrent()
            updateTitle()
        } catch {
            store.notify("Couldn’t create a note: \(error.localizedDescription)")
        }
    }

    /// Every rename comes through here, from the store: the user's, a file following its
    /// first line, and a conflict copy.
    private func noteRenamed(_ old: String, _ new: String) {
        renamed[old] = new
        for (from, to) in renamed where to == old { renamed[from] = new }
        bridge.send("renamed", ["from": old, "to": new])
        if store.current == new { rememberCurrent() }
        updateTitle()
    }

    private func rename(_ old: String, to proposed: String) {
        do {
            _ = try store.rename(old, to: proposed)
        } catch NoteStoreError.exists {
            store.notify("A note named “\(proposed.trimmingCharacters(in: .whitespaces))” already exists.")
        } catch NoteStoreError.invalidName {
            store.notify("A name can’t be empty, start with a period, or contain “/” or “:”.")
        } catch {
            store.notify("Couldn’t rename “\(old)”: \(error.localizedDescription)")
        }
    }

    /// Deleting is easy to do by accident, so it asks first, even though the Trash keeps the note.
    private func confirmTrash(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "Move “\(name)” to the Trash?"
        alert.informativeText = "You can restore it from the Trash in Finder."
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { self?.trash(name) }
                self?.bridge.send("focus", "")
            }
        }
    }

    private func trash(_ name: String) {
        let trashed: String
        do {
            trashed = try store.trash(name)
        } catch {
            store.notify("Couldn’t move “\(name)” to the Trash: \(error.localizedDescription)")
            return
        }
        bridge.send("trashed", trashed)
        if store.current == nil { openSomeNote(keepSwitcher: true) }
        bridge.send("notes", notesForSwitcher())
    }

    private func toggleSwitcher() {
        bridge.send("switcher", ["notes": notesForSwitcher(), "force": false])
    }

    // shortcut: reads every note on each open of the switcher; fine for hundreds of notes.
    private func notesForSwitcher() -> [[String: Any]] {
        store.list().map { note in
            [
                "id": note.name,
                "title": note.name,
                "modified": note.modified.timeIntervalSince1970 * 1000,
                "text": note.name == store.current ? store.text : (store.read(note.name) ?? ""),
            ]
        }
    }

    private func rememberCurrent() {
        UserDefaults.standard.set(store.current, forKey: "lastNote")
    }

    private func updateTitle() {
        let name = store.current ?? ""
        titleLabel.stringValue = name
        panel.title = name
    }

    // MARK: - Window

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.backgroundColor = .textBackgroundColor
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: Self.minHeight)
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.contentView = bridge.webView
        panel.onZoom = { [weak self] step in self?.zoom(step) }
        panel.commands = [
            "n": { [weak self] in self?.newNote() },
            "p": { [weak self] in self?.toggleSwitcher() },
            "w": { [weak self] in self?.hide() },
            "o": { [weak self] in self?.openFolder() },
            ",": { [weak self] in self?.openSettings() },
            // Quitting is in the menu bar icon's menu, so it can't happen by accident while typing.
            "q": {},
        ]

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        buttons = [
            Item.new: toolbarButton("square.and.pencil", "New Note (⌘N)", #selector(newNoteClicked)),
            Item.browse: toolbarButton("list.bullet", "Browse Notes (⌘P)", #selector(browseClicked)),
            Item.folder: toolbarButton("folder", "Open Notes Folder (⌘O)", #selector(openFolderClicked)),
        ]
        applyScale()

        // A unified toolbar gives the title bar room for the larger title and buttons, and
        // keeps the traffic lights centered beside them.
        let toolbar = NSToolbar(identifier: "notepanel")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Item.title]
        panel.toolbar = toolbar
        panel.toolbarStyle = .unified

        if !panel.setFrameUsingName(Self.frameName) { panel.center() }
        panel.setFrameAutosaveName(Self.frameName)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Item.title, .flexibleSpace, Item.new, Item.browse, Item.folder]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier == Item.title {
            item.view = titleLabel
        } else if let button = buttons[identifier] {
            item.view = button
            item.label = button.toolTip ?? ""
        } else {
            return nil
        }
        return item
    }

    private func toolbarButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.identifier = NSUserInterfaceItemIdentifier(symbol)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    /// Sizes the title and the toolbar buttons by the interface size setting.
    private func applyScale() {
        titleLabel.font = .systemFont(ofSize: 13 * uiScale, weight: .semibold)
        let configuration = NSImage.SymbolConfiguration(pointSize: 14 * uiScale, weight: .regular)
        for button in buttons.values {
            guard let symbol = button.identifier?.rawValue else { continue }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.toolTip)?
                .withSymbolConfiguration(configuration)
        }
    }

    @objc private func newNoteClicked() { newNote() }
    @objc private func browseClicked() { toggleSwitcher() }
    @objc private func openFolderClicked() { openFolder() }

    private func fitHeight() {
        guard contentHeight > 0, let screen = panel.screen ?? NSScreen.main else { return }
        let chrome = panel.frame.height - bridge.webView.frame.height
        let visible = screen.visibleFrame
        let frame = fittedFrame(
            panel.frame, height: chrome + contentHeight, minHeight: Self.minHeight,
            maxHeight: visible.height * Self.maxScreenShare, in: visible)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }
}
