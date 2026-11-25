import AppKit
import NotepanelCore

/// Shows and hides the note panel, and connects it to the note store and the editor page.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let store: NoteStore
    var toggleSettings: () -> Void = {}
    /// When the panel moves to another display, whose default Settings then shows.
    var onScreenChange: () -> Void = {}

    private let panel: NotePanel
    private let bridge = EditorBridge()
    /// The background under the note's page.
    private let backdrop: Backdrop
    private var backgroundOpacity: Double?
    private let titleBar: TitleBar
    private let switcher: SwitcherWindow
    private var previousApp: NSRunningApplication?
    private var options: NSDictionary = [:]
    /// Counts the notes shown in the page, which sends the count back with the text typed. Text
    /// typed in a note the panel has since left arrives late, and isn't taken for the open note's.
    private var opening = 0

    private static let frameName = "Note Panel"
    /// ⌃⌘M, and the default place for each display that Settings shows and sets.
    let placement: PanelPlacement

    init(store: NoteStore) {
        self.store = store
        panel = NotePanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        placement = PanelPlacement(panel: panel)
        // The page draws no background of its own, so the backdrop shows through it.
        bridge.webView.setValue(false, forKey: "drawsBackground")
        backdrop = Backdrop(behind: bridge.webView)
        titleBar = TitleBar(panel: panel, store: store)
        switcher = SwitcherWindow(panel: panel, notePage: bridge.webView)
        super.init()
        titleBar.onHistory = { [weak self] in self?.toggleHistory() }
        titleBar.onBrowse = { [weak self] in self?.showSwitcher(find: false, toggle: true) }
        titleBar.onNewNote = { [weak self] in self?.newNote() }
        titleBar.onOpenFolder = { [weak self] in self?.openFolder() }
        titleBar.onRename = { [weak self] name, proposed in self?.rename(name, to: proposed) }
        titleBar.focusEditor = { [weak self] in self?.focusEditor() }
        configurePanel()
        switcher.configure()
        // The panel tells its delegate when it takes the keys; the switcher's window has none.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification,
            object: switcher.window)
        store.onStatus = { [weak self] message in self?.bridge.send("status", message ?? "") }
        store.onRenamed = { [weak self] from, to in self?.noteRenamed(from, to) }
        store.onSaveState = { [weak self] _ in self?.titleBar.showSaveState() }
        bridge.onMessage = { [weak self] type, body in self?.handle(type, body) }
        switcher.bridge.onMessage = { [weak self] type, body in self?.handleSwitcher(type, body) }
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Showing and hiding

    func show() {
        if !panel.isVisible {
            // The app in front is noted as the panel takes the keys. If it's this app, hiding the
            // panel leaves the keys with Settings or the keys window.
            previousApp = nil
            if store.reloadIfChanged() != nil { showNote() }
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        // The switcher went with the panel, and comes back with it.
        if switcher.isShown { switcher.attach() }
        focusEditor()
    }

    /// Returns focus to the app that was in front, unless the user has moved on to another one.
    /// Saving comes after the panel is gone, so writing the file doesn't hold it on screen.
    func hide() {
        if panel.isVisible {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let movedOn = front != NSRunningApplication.current.processIdentifier && front != previousApp?.processIdentifier
            panel.orderOut(nil)
            switcher.window.orderOut(nil)
            titleBar.pointerLeft()
            if !movedOn { _ = previousApp?.activate(options: []) }
        }
        store.flush()
    }

    /// Hides the panel if it's in front, and otherwise brings it forward. The switcher's window
    /// counts as the panel.
    func toggle() {
        if panel.isVisible && (panel.isKeyWindow || switcher.isKey) { hide() } else { show() }
    }

    func newNote() {
        createNote()
        show()
    }

    /// Escape takes the panel away again if searching is what brought it up.
    func search() {
        let wasHidden = !panel.isVisible
        show()
        showSwitcher(find: true, force: true, dismiss: wasHidden)
    }

    /// The switcher is a window of its own, outside the panel, so the note and the title bar stay
    /// as they are. Its page says when the switcher has come up or wants the focus again, and when
    /// it has closed.
    private func setSwitcherShown(_ shown: Bool) {
        if shown != switcher.isShown {
            if shown {
                switcher.open()
            } else {
                switcher.close()
                bridge.send("marks", "")
                // The note takes the typing the switcher's window had.
                if panel.isVisible { panel.makeKey() }
                focusEditor()
            }
        }
        // A switcher brought up after the panel has gone comes back with the panel.
        guard shown, panel.isVisible else { return }
        switcher.attach()
        switcher.focus()
    }

    /// Ends typing in the title, so the name goes to its note, and saves the note. The switcher
    /// and the history show what's on disk, and quitting leaves it there.
    func save() {
        titleBar.finishTitle()
        store.flush()
    }

    /// Opens the notes folder in Finder with the open note's file selected. With no note open, or
    /// its file gone, the folder opens with nothing selected.
    func openFolder() {
        try? FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        let note = store.current.map(store.url)
        if let note, FileManager.default.fileExists(atPath: note.path) {
            NSWorkspace.shared.activateFileViewerSelecting([note])
        } else {
            NSWorkspace.shared.open(store.folder)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    /// The panel or the switcher's window took the keys. The app becomes active, so that tools that
    /// act on the active app's focused window, such as window managers, act on the panel. The app
    /// the keys came from gets them back when the panel hides.
    func windowDidBecomeKey(_ notification: Notification) {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != NSRunningApplication.current.processIdentifier { previousApp = front }
        // Not activate(), which macOS may turn down when the user hasn't just clicked in the app,
        // as when a hot key shows the panel.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Whether the panel's own commands use this key, which Settings won't give a shortcut.
    func panelTakes(_ event: NSEvent) -> Bool {
        panel.takes(event)
    }

    /// Narrows the name before the toolbar lays out the new width: narrowed only afterwards, a long
    /// name leaves the buttons no room for a moment when the panel shrinks fast, and they start to
    /// move into the overflow menu. AppKit calls this as the user drags, but not for
    /// setFrame(_:display:), which windowDidResize covers.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        titleBar.sizeTitle(panelWidth: frameSize.width)
        return frameSize
    }

    func windowDidResize(_ notification: Notification) {
        titleBar.sizeTitle()
        if switcher.isShown { switcher.place() }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        onScreenChange()
    }

    // MARK: - Settings

    func setFolder(_ dataFolder: URL) {
        guard dataFolder.standardizedFileURL != store.dataFolder.standardizedFileURL else { return }
        titleBar.finishTitle()
        store.setFolder(dataFolder)
        UserDefaults.standard.removeObject(forKey: Prefs.Key.lastNote)
        // A note that couldn't be saved in the old folder is still open, and is the new folder's now.
        if store.current == nil { openSomeNote() } else { rememberCurrent() }
    }

    func setOptions(fontFamily: String, fontSize: Double, uiFontSize: Double, showWhitespace: Bool, indentSize: Int) {
        let new: NSDictionary = [
            "fontFamily": fontFamily, "fontSize": fontSize, "uiFontSize": uiFontSize,
            "showWhitespace": showWhitespace, "indentSize": indentSize,
        ]
        guard new != options else { return }
        options = new
        bridge.send("options", new)
        switcher.bridge.send("options", new)
        titleBar.uiFontSize = CGFloat(uiFontSize)
    }

    func setPanelShortcuts(next: Shortcut?, previous: Shortcut?, defaultFrame: Shortcut?) {
        var shortcuts: [(shortcut: Shortcut, repeats: Bool, action: () -> Void)] = []
        if let next { shortcuts.append((next, true, { [weak self] in self?.cycle(1) })) }
        if let previous { shortcuts.append((previous, true, { [weak self] in self?.cycle(-1) })) }
        if let defaultFrame { shortcuts.append((defaultFrame, false, { [weak self] in self?.placement.toggleDefaultFrame() })) }
        panel.shortcuts = shortcuts
        switcher.window.shortcuts = shortcuts
    }

    /// The background's opacity, the panel's and the switcher's; the text keeps its own.
    func setBackgroundOpacity(_ opacity: Double) {
        let opacity = min(1, max(0, opacity))
        guard opacity != backgroundOpacity else { return }
        backgroundOpacity = opacity
        backdrop.setOpacity(opacity)
        switcher.backdrop.setOpacity(opacity)
        // With nothing behind the text, the shadow would outline the letters.
        panel.hasShadow = opacity > 0
        panel.invalidateShadow()
    }

    /// Cmd-plus and Cmd-minus step the note's text size; Cmd-0 sets it to the default for the
    /// panel's display, as ⌃⌘M does. It's the same setting as in the settings window.
    private func zoom(_ step: Int) {
        let defaults = UserDefaults.standard
        let size = defaults.object(forKey: Prefs.Key.fontSize) as? Double ?? Prefs.defaultFontSize
        let new = step == 0 ? placement.defaultFontSize : size + Double(step)
        defaults.set(min(Prefs.fontSizes.upperBound, max(Prefs.fontSizes.lowerBound, new)), forKey: Prefs.Key.fontSize)
    }

    // MARK: - Messages from the pages

    /// From the note's page, in the panel.
    private func handle(_ type: String, _ body: [String: Any]) {
        switch type {
        case "ready":
            // Also after the page reloads: it gets its options again, and the open note from the
            // store, whose text may not be on disk.
            bridge.send("options", options)
            titleBar.historyShown = false
            if store.current == nil { openSomeNote() } else { showNote() }
        case "changed":
            guard body["opening"] as? Int == opening, let text = body["text"] as? String else { return }
            store.edit(text)
        case "openURL":
            // The page is trusted, but a link can say anything, so only web and mail links open.
            guard let string = body["url"] as? String, let url = URL(string: string),
                ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
            else { return }
            NSWorkspace.shared.open(url)
        case "copy":
            // From the link popup's Copy button; plain text, so it pastes anywhere.
            guard let text = body["text"] as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case "escape":
            // The switcher goes first, if it's up beside the note.
            if switcher.isShown { closeSwitcher() } else { hide() }
        case "historyShown":
            titleBar.historyShown = body["shown"] as? Bool ?? false
        default:
            break
        }
    }

    /// From the switcher's page, in its window. A row's note opens in the note's page, which is
    /// told where to put the cursor (`land`) and what the search finds in it (`marks`).
    private func handleSwitcher(_ type: String, _ body: [String: Any]) {
        switch type {
        case "ready":
            // Also after the page reloads, which closes the switcher.
            switcher.bridge.send("side", true)
            switcher.bridge.send("options", options)
            setSwitcherShown(false)
        case "select":
            if let id = body["id"] as? String { open(id, keepSwitcher: true, land: body["land"]) }
        case "marks":
            bridge.send("marks", body["query"] as? String ?? "")
        case "switcherShown":
            if let height = body["height"] as? Double { switcher.maxHeight = CGFloat(height) }
            setSwitcherShown(body["shown"] as? Bool ?? false)
        case "sideWidth":
            if let width = body["width"] as? Double { switcher.setWidth(CGFloat(width)) }
        case "trash":
            if let id = body["id"] as? String { confirmTrash(id) }
        case "pin":
            if let id = body["id"] as? String { togglePin(id) }
        case "orderPins":
            if let ids = body["ids"] as? [String] { orderPins(ids) }
        case "escape":
            // The search hot key brought the panel up, and Escape takes it away again.
            hide()
        default:
            break
        }
    }

    // MARK: - Notes

    @discardableResult
    private func open(_ name: String, keepSwitcher: Bool = false, land: Any? = nil) -> Bool {
        titleBar.finishTitle()
        guard store.open(name) != nil else { return false }
        showNote(keepSwitcher: keepSwitcher, land: land)
        return true
    }

    /// Shows the open note in the page. `land` is where the switcher's row puts the cursor, which
    /// the page works out. A note opened some other way than from the switcher's list closes the
    /// switcher, or with `keepSwitcher` is chosen in its list.
    private func showNote(keepSwitcher: Bool = false, land: Any? = nil) {
        guard let name = store.current else { return }
        opening += 1
        var message: [String: Any] = ["id": name, "text": store.text, "opening": opening]
        message["land"] = land
        bridge.send("open", message)
        if !keepSwitcher {
            closeSwitcher()
        } else if land == nil, switcher.isShown {
            switcher.bridge.send("current", name)
        }
        rememberCurrent()
        titleBar.updateTitle()
    }

    /// Opens the last note, else the newest readable one, else a new one, so a note is always open.
    private func openSomeNote(keepSwitcher: Bool = false) {
        let names = store.list().map(\.name)
        var candidates = names
        if let last = UserDefaults.standard.string(forKey: Prefs.Key.lastNote), names.contains(last) {
            candidates.insert(last, at: 0)
        }
        for name in candidates {
            if open(name, keepSwitcher: keepSwitcher) { return }
        }
        createNote(keepSwitcher: keepSwitcher)
    }

    private func createNote(keepSwitcher: Bool = false) {
        titleBar.finishTitle()
        do {
            _ = try store.create()
            showNote(keepSwitcher: keepSwitcher)
        } catch NoteStoreError.unsaved {
            // The footer already says that the open note stays.
        } catch {
            store.notify("Couldn’t create a note: \(error.localizedDescription)")
        }
    }

    /// Opens the next or previous note in the switcher's order, wrapping around. A note that
    /// can't be read, such as one that isn't UTF-8 text, is passed over, so cycling goes on.
    private func cycle(_ step: Int) {
        let names = orderedNotes()
        guard let current = store.current, let index = names.firstIndex(of: current) else { return }
        let count = names.count
        let others = (1..<count).map { names[((index + step * $0) % count + count) % count] }
        if let next = others.first(where: { store.read($0) != nil }) { open(next, keepSwitcher: true) }
    }

    /// Every rename comes through here, from the store: the user's, a file following its
    /// first line, and a conflict copy.
    private func noteRenamed(_ old: String, _ new: String) {
        let pins = Prefs.pinned(in: store.folder)
        let renamed = pinsRenaming(pins, old, to: new)
        if renamed != pins { Prefs.setPinned(renamed, in: store.folder) }
        for page in [bridge, switcher.bridge] { page.send("renamed", ["from": old, "to": new]) }
        if store.current == new { rememberCurrent() }
        titleBar.updateTitle()
    }

    private func rename(_ old: String, to proposed: String) {
        do {
            _ = try store.rename(old, to: proposed)
        } catch NoteStoreError.exists {
            store.notify("A note named “\(proposed.trimmingCharacters(in: .whitespaces))” already exists.")
        } catch NoteStoreError.invalidName {
            store.notify(
                "A name can’t be empty or longer than \(nameLimit) bytes, start with a period, or contain “/” or “:”.")
        } catch {
            store.notify("Couldn’t rename “\(old)”: \(error.localizedDescription)")
        }
    }

    /// Deleting is easy to do by accident, so it asks first, even though the Trash keeps the note.
    /// Only the switcher asks, so the focus goes back there, where its page had it.
    private func confirmTrash(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "Move “\(name)” to the Trash?"
        alert.informativeText = "You can restore it from the Trash in Finder."
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .alertFirstButtonReturn { self.trash(name) }
                if self.switcher.isShown {
                    self.switcher.focus()
                    self.switcher.bridge.send("focus", "")
                } else {
                    self.focusEditor()
                }
            }
        }
    }

    private func trash(_ name: String) {
        let trashed: String
        do {
            trashed = try store.trash(name)
        } catch NoteStoreError.unsaved {
            return  // The footer already says that the open note stays.
        } catch {
            store.notify("Couldn’t move “\(name)” to the Trash: \(error.localizedDescription)")
            return
        }
        Prefs.setPinned(Prefs.pinned(in: store.folder).filter { $0 != trashed }, in: store.folder)
        bridge.send("trashed", trashed)
        switcher.bridge.send("notes", notesForSwitcher())
        if store.current == nil { openSomeNote(keepSwitcher: true) }
    }

    private func togglePin(_ name: String) {
        Prefs.setPinned(pinsToggling(Prefs.pinned(in: store.folder), name), in: store.folder)
        switcher.bridge.send("notes", notesForSwitcher())
    }

    /// The page sends the pinned notes it shows, in their new order.
    private func orderPins(_ ids: [String]) {
        guard let pins = pinsReordered(Prefs.pinned(in: store.folder), shown: ids) else { return }
        Prefs.setPinned(pins, in: store.folder)
        switcher.bridge.send("notes", notesForSwitcher())
    }

    /// Cmd-1 to Cmd-9 open the first to ninth pinned note.
    private func openPinned(_ number: Int) {
        let pins = Set(Prefs.pinned(in: store.folder))
        let pinned = orderedNotes().filter { pins.contains($0) }
        if pinned.indices.contains(number - 1) { open(pinned[number - 1]) }
    }

    /// ⌘P: the switcher with the focus in its list, to go from note to note. The page closes it
    /// if the focus is there already, as it does for ⌘F and the search field.
    private func toggleSwitcher() {
        showSwitcher(find: false)
    }

    /// ⌘F: the switcher with the focus in its search field. With some of a line selected in the
    /// note, it searches for that at once, so the note's page is asked what's selected first.
    private func find() {
        guard panel.isKeyWindow else {
            showSwitcher(find: true)
            return
        }
        bridge.webView.evaluateJavaScript("findText()") { [weak self] picked, _ in
            MainActor.assumeIsolated { self?.showSwitcher(find: true, picked: picked as? String ?? "") }
        }
    }

    /// Saves first, so the list has the open note under the name its first line gives it.
    /// With `find` the focus goes to the search field, and else to the list. `force` never closes
    /// the switcher, and `toggle` closes it wherever the focus is. With `dismiss`, Escape in the
    /// switcher hides the panel too. `picked` is text to search for at once.
    private func showSwitcher(
        find: Bool, force: Bool = false, toggle: Bool = false, dismiss: Bool = false, picked: String = ""
    ) {
        save()
        switcher.bridge.send(
            "switcher",
            [
                "notes": notesForSwitcher(), "current": store.current ?? "", "key": switcher.isKey,
                "find": find, "force": force, "toggle": toggle, "dismiss": dismiss, "picked": picked,
            ])
    }

    /// The switcher's page closes the switcher and says so, and then its window goes.
    private func closeSwitcher() {
        if switcher.isShown { switcher.bridge.send("close", "") }
    }

    /// ⌘Y: the open note's earlier versions, newest first, to copy from. Nothing there changes
    /// the note.
    private func toggleHistory() {
        save()
        guard let name = store.current else { return }
        let dates = ISO8601DateFormatter()
        let versions = store.versions(of: name).map { ["date": dates.string(from: $0.date), "text": $0.text] }
        bridge.send("history", ["id": name, "versions": versions])
        // It takes the keys, also from the switcher, which stays beside it.
        panel.makeKey()
        focusEditor()
    }

    /// Pinned notes first, in the order the user gave them, then the rest, newest first. The
    /// switcher, cycling and Cmd-1 to Cmd-9 share it.
    private func orderedNotes() -> [String] {
        pinnedFirst(store.list().map(\.name), pins: Prefs.pinned(in: store.folder))
    }

    // shortcut: reads every note on each open of the switcher; fine for hundreds of notes.
    private func notesForSwitcher() -> [[String: Any]] {
        let pins = Set(Prefs.pinned(in: store.folder))
        return orderedNotes().map { name in
            [
                "id": name,
                "title": name,
                "pinned": pins.contains(name),
                "text": name == store.current ? store.text : (store.read(name) ?? ""),
            ]
        }
    }

    private func rememberCurrent() {
        UserDefaults.standard.set(store.current, forKey: Prefs.Key.lastNote)
    }

    // MARK: - Window

    private func configurePanel() {
        panel.float()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        // Added after creating the panel, which keeps its frame: with this in the style mask, the
        // content rect it's created with would cover the title bar too, making it shorter.
        panel.styleMask.insert(.fullSizeContentView)
        panel.minSize = NSSize(width: 320, height: 160)
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        // Set explicitly, so clicks where the background is clear reach the panel, not the app behind.
        panel.ignoresMouseEvents = false
        panel.contentView = backdrop.view
        panel.onZoom = { [weak self] step in self?.zoom(step) }
        panel.commands = [
            "n": { [weak self] in self?.newNote() },
            "p": { [weak self] in self?.toggleSwitcher() },
            // Finding is the switcher's too: in this note as it's typed, and in the others.
            "f": { [weak self] in self?.find() },
            "y": { [weak self] in self?.toggleHistory() },
            "w": { [weak self] in self?.hide() },
            "o": { [weak self] in self?.openFolder() },
            ",": { [weak self] in self?.toggleSettings() },
            "?": { KeysWindow.toggle() },
            // Quitting saves first, and asks if something couldn't be saved.
            "q": { NSApp.terminate(nil) },
        ]
        for number in 1...9 {
            panel.commands[String(number)] = { [weak self] in self?.openPinned(number) }
        }

        titleBar.install()

        // The panel keeps the size the user gives it; nothing resizes it to fit a note.
        placement.defaultSize = panel.frame.size
        if !panel.setFrameUsingName(Self.frameName) { panel.center() }
        panel.setFrameAutosaveName(Self.frameName)
    }

    private func focusEditor() {
        panel.makeFirstResponder(bridge.webView)
        bridge.send("focus", "")
    }
}
