import AppKit
import NotepanelCore

/// Shows and hides the note panel, and connects it to the note store and the editor page.
@MainActor
final class PanelController: NSObject, NSWindowDelegate, NSToolbarDelegate, NSTextFieldDelegate {
    let store: NoteStore
    var toggleSettings: () -> Void = {}
    /// When the panel moves to another display, whose default Settings then shows.
    var onScreenChange: () -> Void = {}

    private let panel: NotePanel
    private let bridge = EditorBridge()
    /// The switcher's window, at the panel's left, with the same page in a web view of its own.
    /// Borderless, so its shape is its glass's.
    private let side = NotePanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let sideBridge = EditorBridge()
    /// The background under each page, the panel's and the switcher's: glass, with a scrim over it.
    private var backdrops: [(glass: NSView, scrim: NSBox)] = []
    private var backgroundOpacity: Double?
    private let titleField: NSTextField = NameField(string: "")
    private var titleWidth: NSLayoutConstraint!
    /// The save icon and the name, as one toolbar item.
    private let titleView = NSView()
    /// Also the history button.
    private let saveIcon = HistoryButton()
    private var saveIconWidth: NSLayoutConstraint!
    private var saveIconGap: NSLayoutConstraint!
    /// Whether the page shows the history, as it last said.
    private var historyShown = false
    /// Whether the switcher's page shows the switcher, as it last said.
    private var switcherShown = false
    /// The switcher's width, in points. Dragging the switcher's left edge changes it, and it's
    /// kept when the switcher closes.
    private var sideWidth = CGFloat(
        max(Prefs.minSideWidth, UserDefaults.standard.object(forKey: "sideWidth") as? Double ?? Prefs.defaultSideWidth))
    /// Where the panel was and where it went, when it moved right to make room for the switcher.
    private var shift: (from: NSRect, to: NSRect)?
    private var buttons: [NSButton] = []
    /// The buttons at the right, as one toolbar item.
    private let buttonsView = ButtonRow()
    /// The switcher's button, at the left, over the switcher.
    private let browseView = ButtonRow()
    private var previousApp: NSRunningApplication?
    private var uiFontSize: CGFloat = 15
    private var options: NSDictionary = [:]
    /// Counts the notes shown in the page, which sends the count back with the text typed. Text
    /// typed in a note the panel has since left arrives late, and isn't taken for the open note's.
    private var opening = 0

    private static let frameName = "Note Panel"
    /// The panel's size before a saved frame replaces it, which ⌃⌘M goes back to.
    private var defaultSize = NSSize.zero
    /// Where ⌃⌘M found the panel and where it put it, so a second press, before the panel moves
    /// or changes size, takes it back.
    private var frameBeforeDefault: NSRect?
    private var defaultFrame: NSRect?

    private enum Item {
        static let browse = NSToolbarItem.Identifier("browse")
        static let title = NSToolbarItem.Identifier("title")
        static let buttons = NSToolbarItem.Identifier("buttons")
    }

    init(store: NoteStore) {
        self.store = store
        panel = NotePanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()
        configurePanel()
        configureSide()
        store.onStatus = { [weak self] message in self?.bridge.send("status", message ?? "") }
        store.onRenamed = { [weak self] from, to in self?.noteRenamed(from, to) }
        store.onSaveState = { [weak self] _ in self?.showSaveState() }
        bridge.onMessage = { [weak self] type, body in self?.handle(type, body) }
        sideBridge.onMessage = { [weak self] type, body in self?.handleSwitcher(type, body) }
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Showing and hiding

    func show() {
        if !panel.isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == NSRunningApplication.current.processIdentifier ? nil : front
            if store.reloadIfChanged() != nil { showNote() }
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        // The switcher went with the panel, and comes back with it.
        if switcherShown { attachSide() }
        focusEditor()
    }

    /// Returns focus to the app that was in front, unless the user has moved on to another one.
    /// Saving comes after the panel is gone, so writing the file doesn't hold it on screen.
    func hide() {
        if panel.isVisible {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let movedOn = front != NSRunningApplication.current.processIdentifier && front != previousApp?.processIdentifier
            panel.orderOut(nil)
            side.orderOut(nil)
            // The pointer leaves the icon with the panel, and no exit says so.
            saveIcon.pointing = false
            if !movedOn { _ = previousApp?.activate(options: []) }
        }
        store.flush()
    }

    /// Hides the panel if it's in front, and otherwise brings it forward. The switcher's window
    /// counts as the panel.
    func toggle() {
        if panel.isVisible && (panel.isKeyWindow || side.isKeyWindow) { hide() } else { show() }
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
    /// it has closed. While it's up, the window is the panel's child, which moves with it.
    private func setSwitcherShown(_ shown: Bool) {
        if shown != switcherShown {
            switcherShown = shown
            bridge.send("switcherShown", shown)
            if shown {
                // Where the display has no room at the panel's left, the panel moves right while
                // the switcher is up, and back when it closes, unless it was moved meanwhile.
                let room = panel.frame.minX - (panel.screen?.visibleFrame.minX ?? panel.frame.minX - sideWidth)
                if room < sideWidth {
                    let from = panel.frame
                    panel.setFrameOrigin(NSPoint(x: from.minX + sideWidth - room, y: from.minY))
                    shift = (from, panel.frame)
                }
            } else {
                panel.removeChildWindow(side)
                side.orderOut(nil)
                UserDefaults.standard.set(Double(sideWidth), forKey: "sideWidth")
                if let shift, panel.frame == shift.to { panel.setFrame(shift.from, display: true) }
                shift = nil
                focusEditor()
            }
        }
        // A switcher brought up after the panel has gone comes back with the panel.
        guard shown, panel.isVisible else { return }
        attachSide()
        focusSwitcher()
    }

    /// The switcher's window goes at the panel's left, flush with it, from under the title bar to
    /// the bottom: beside the note's page.
    private func placeSide() {
        let page = panel.convertToScreen(bridge.webView.convert(bridge.webView.bounds, to: nil))
        side.setFrame(NSRect(x: page.minX - sideWidth, y: page.minY, width: sideWidth, height: page.height), display: true)
        side.invalidateShadow()
    }

    private func attachSide() {
        placeSide()
        if side.parent == nil { panel.addChildWindow(side, ordered: .above) }
        side.orderFront(nil)
    }

    /// Typing goes to the switcher's page, where it put the focus.
    private func focusSwitcher() {
        side.makeKeyAndOrderFront(nil)
        side.makeFirstResponder(sideBridge.webView)
    }

    /// Ends typing in the title, so the name goes to its note, and saves the note. The switcher
    /// and the history show what's on disk, and quitting leaves it there.
    func save() {
        finishTitle()
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

    /// ⌃⌘M: the default frame set in Settings for the display with the pointer, or else the panel's
    /// first size, centered there. Using the pointer's display brings the panel to the display in
    /// use. Pressed again before the panel moves or changes size, it goes back to where it was.
    private func toggleDefaultFrame() {
        // shortcut: the switcher gets room at the panel's left only as it opens, so ⌃⌘M waits until
        // it closes.
        guard !switcherShown else { return }
        if let previous = frameBeforeDefault, panel.frame == defaultFrame {
            panel.setFrame(previous, display: true)
            frameBeforeDefault = nil
            return
        }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main
        else { return }
        frameBeforeDefault = panel.frame
        let saved = screen.displayKey.flatMap { Prefs.defaultFrame(for: $0) }
        panel.setFrame(
            placeOnDisplay(saved: saved, size: defaultSize, display: screen.frame, visible: screen.visibleFrame),
            display: true)
        defaultFrame = panel.frame
    }

    /// The display the panel is on, as Settings shows it, and its default for ⌃⌘M.
    func defaultPlace() -> DefaultPlace? {
        guard let screen = panelScreen, let key = screen.displayKey else { return nil }
        let saved = Prefs.defaultFrame(for: key)
        let builtIn = screen.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
        let display = screen.frame
        let frame = placeOnDisplay(saved: saved, size: defaultSize, display: display, visible: screen.visibleFrame)
        return DefaultPlace(
            display: screen.localizedName, builtIn: builtIn, displaySize: display.size,
            menuBar: display.maxY - screen.visibleFrame.maxY,
            // AppKit's y goes up from the bottom; screen positions are usually shown from the top-left.
            frame: NSRect(
                x: frame.minX - display.minX, y: display.maxY - frame.maxY, width: frame.width, height: frame.height),
            custom: saved != nil)
    }

    /// Whether the panel's own commands use this key, which Settings won't give a shortcut.
    func panelTakes(_ event: NSEvent) -> Bool {
        panel.takes(event)
    }

    /// Settings' Use Current: on the panel's display, ⌃⌘M will put the panel where it is now.
    func useCurrentFrameAsDefault() {
        guard let screen = panelScreen, let key = screen.displayKey else { return }
        Prefs.setDefaultFrame(panel.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), for: key)
    }

    /// Settings' Reset: on the panel's display, ⌃⌘M will use the first size, centered.
    func useStandardFrame() {
        guard let key = panelScreen?.displayKey else { return }
        Prefs.setDefaultFrame(nil, for: key)
    }

    /// The display most of the panel is on. Worked out from the frame, as `NSWindow.screen` may be
    /// nil while the panel is hidden.
    private var panelScreen: NSScreen? {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(panel.frame)
            return shared.width * shared.height
        }
        return NSScreen.screens.filter { overlap($0) > 0 }.max { overlap($0) < overlap($1) }
    }

    /// Narrows the name before the toolbar lays out the new width: narrowed only afterwards, a long
    /// name leaves the buttons no room for a moment when the panel shrinks fast, and they start to
    /// move into the overflow menu. AppKit calls this as the user drags, but not for
    /// setFrame(_:display:), which windowDidResize covers.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        sizeTitle(panelWidth: frameSize.width)
        return frameSize
    }

    func windowDidResize(_ notification: Notification) {
        sizeTitle()
        if switcherShown { placeSide() }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        onScreenChange()
    }

    // MARK: - Settings

    func setFolder(_ dataFolder: URL) {
        guard dataFolder.standardizedFileURL != store.dataFolder.standardizedFileURL else { return }
        finishTitle()
        store.setFolder(dataFolder)
        UserDefaults.standard.removeObject(forKey: "lastNote")
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
        sideBridge.send("options", new)
        if CGFloat(uiFontSize) != self.uiFontSize {
            self.uiFontSize = CGFloat(uiFontSize)
            applyUIFontSize()
        }
    }

    func setPanelShortcuts(next: Shortcut?, previous: Shortcut?, defaultFrame: Shortcut?) {
        var shortcuts: [(shortcut: Shortcut, repeats: Bool, action: () -> Void)] = []
        if let next { shortcuts.append((next, true, { [weak self] in self?.cycle(1) })) }
        if let previous { shortcuts.append((previous, true, { [weak self] in self?.cycle(-1) })) }
        if let defaultFrame { shortcuts.append((defaultFrame, false, { [weak self] in self?.toggleDefaultFrame() })) }
        panel.shortcuts = shortcuts
        side.shortcuts = shortcuts
    }

    /// The background's opacity; the text keeps its own. 0 leaves nothing behind the text, the
    /// default is tinycast's background, and 1 is solid. Up to the default, the glass and the
    /// scrim fade in together; past it, the scrim gets more opaque.
    func setBackgroundOpacity(_ opacity: Double) {
        let opacity = min(1, max(0, opacity))
        guard opacity != backgroundOpacity else { return }
        backgroundOpacity = opacity
        let middle = Prefs.defaultBackgroundOpacity
        let fade = CGFloat(min(1, opacity / middle))
        let color = Self.scrimColor(solid: max(0, (opacity - middle) / (1 - middle)))
        for (glass, scrim) in backdrops {
            glass.alphaValue = fade
            scrim.alphaValue = fade
            scrim.fillColor = color
        }
        // With nothing behind the text, the shadow would outline the letters.
        for window in [panel, side] {
            window.hasShadow = fade > 0
            window.invalidateShadow()
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

    // MARK: - Messages from the pages

    /// From the note's page, in the panel.
    private func handle(_ type: String, _ body: [String: Any]) {
        switch type {
        case "ready":
            // Also after the page reloads: it gets its options again, and the open note from the
            // store, whose text may not be on disk.
            bridge.send("options", options)
            historyShown = false
            showSaveState()
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
            if switcherShown { closeSwitcher() } else { hide() }
        case "historyShown":
            historyShown = body["shown"] as? Bool ?? false
            showSaveState()
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
            sideBridge.send("side", true)
            sideBridge.send("options", options)
            setSwitcherShown(false)
        case "select":
            if let id = body["id"] as? String { open(id, keepSwitcher: true, land: body["land"]) }
        case "marks":
            bridge.send("marks", body["query"] as? String ?? "")
        case "switcherShown":
            setSwitcherShown(body["shown"] as? Bool ?? false)
        case "sideWidth":
            // As far as the display goes to the left.
            guard let width = body["width"] as? Double else { return }
            let room = panel.frame.minX - (panel.screen?.visibleFrame.minX ?? -.greatestFiniteMagnitude)
            sideWidth = max(CGFloat(Prefs.minSideWidth), min(CGFloat(width), room))
            placeSide()
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
        finishTitle()
        guard store.open(name) != nil else { return false }
        showNote(keepSwitcher: keepSwitcher, land: land)
        return true
    }

    /// Shows the open note in the page. A note opened some other way than from the switcher's list
    /// closes the switcher. `land` is where the switcher's row puts the cursor, which the page
    /// works out.
    private func showNote(keepSwitcher: Bool = false, land: Any? = nil) {
        guard let name = store.current else { return }
        opening += 1
        var message: [String: Any] = ["id": name, "text": store.text, "opening": opening]
        message["land"] = land
        bridge.send("open", message)
        if !keepSwitcher { closeSwitcher() }
        rememberCurrent()
        updateTitle()
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
        finishTitle()
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
        let names = orderedNotes().map(\.name)
        guard let current = store.current, let index = names.firstIndex(of: current) else { return }
        let count = names.count
        let others = (1..<count).map { names[((index + step * $0) % count + count) % count] }
        if let next = others.first(where: { store.read($0) != nil }) { open(next) }
    }

    /// Every rename comes through here, from the store: the user's, a file following its
    /// first line, and a conflict copy.
    private func noteRenamed(_ old: String, _ new: String) {
        var pins = Prefs.pinned(in: store.folder)
        if let index = pins.firstIndex(of: old) {
            pins[index] = new
            Prefs.setPinned(pins, in: store.folder)
        }
        for page in [bridge, sideBridge] { page.send("renamed", ["from": old, "to": new]) }
        if store.current == new { rememberCurrent() }
        updateTitle()
    }

    private func rename(_ old: String, to proposed: String) {
        do {
            _ = try store.rename(old, to: proposed)
        } catch NoteStoreError.exists {
            store.notify("A note named “\(proposed.trimmingCharacters(in: .whitespaces))” already exists.")
        } catch NoteStoreError.invalidName {
            store.notify("A name can’t be empty or longer than 240 bytes, start with a period, or contain “/” or “:”.")
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
                if self.switcherShown {
                    self.focusSwitcher()
                    self.sideBridge.send("focus", "")
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
        if store.current == nil { openSomeNote(keepSwitcher: true) }
        sideBridge.send("notes", notesForSwitcher())
    }

    private func togglePin(_ name: String) {
        var pins = Prefs.pinned(in: store.folder)
        if let index = pins.firstIndex(of: name) { pins.remove(at: index) } else { pins.append(name) }
        Prefs.setPinned(pins, in: store.folder)
        sideBridge.send("notes", notesForSwitcher())
    }

    /// The page sends the pinned notes it shows, in their new order. Pins whose file is missing
    /// aren't shown, so they keep their place after the others.
    private func orderPins(_ ids: [String]) {
        let pins = Prefs.pinned(in: store.folder)
        guard Set(ids).count == ids.count, Set(ids).isSubset(of: pins) else { return }
        Prefs.setPinned(ids + pins.filter { !ids.contains($0) }, in: store.folder)
        sideBridge.send("notes", notesForSwitcher())
    }

    /// Cmd-1 to Cmd-9 open the first to ninth pinned note.
    private func openPinned(_ number: Int) {
        let pins = Set(Prefs.pinned(in: store.folder))
        let pinned = orderedNotes().filter { pins.contains($0.name) }
        if pinned.indices.contains(number - 1) { open(pinned[number - 1].name) }
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
        sideBridge.send(
            "switcher",
            [
                "notes": notesForSwitcher(), "current": store.current ?? "", "key": side.isKeyWindow,
                "find": find, "force": force, "toggle": toggle, "dismiss": dismiss, "picked": picked,
            ])
    }

    /// The switcher's page closes the switcher and says so, and then its window goes.
    private func closeSwitcher() {
        if switcherShown { sideBridge.send("close", "") }
    }

    /// ⌘Y: the open note's earlier versions, newest first, to copy from. Nothing there changes
    /// the note.
    private func toggleHistory() {
        save()
        guard let name = store.current else { return }
        // The history would cover the note the switcher shows.
        closeSwitcher()
        let dates = ISO8601DateFormatter()
        let versions = store.versions(of: name).map { ["date": dates.string(from: $0.date), "text": $0.text] }
        bridge.send("history", ["id": name, "versions": versions])
    }

    /// Pinned notes first, in the order the user gave them, then the rest, newest first. The
    /// switcher, cycling and Cmd-1 to Cmd-9 share it.
    private func orderedNotes() -> [NoteInfo] {
        let pins = Prefs.pinned(in: store.folder)
        let notes = store.list()
        let pinned = pins.compactMap { name in notes.first { $0.name == name } }
        return pinned + notes.filter { !pins.contains($0.name) }
    }

    // shortcut: reads every note on each open of the switcher; fine for hundreds of notes.
    private func notesForSwitcher() -> [[String: Any]] {
        let pins = Set(Prefs.pinned(in: store.folder))
        return orderedNotes().map { note in
            [
                "id": note.name,
                "title": note.name,
                "pinned": pins.contains(note.name),
                "text": note.name == store.current ? store.text : (store.read(note.name) ?? ""),
            ]
        }
    }

    private func rememberCurrent() {
        UserDefaults.standard.set(store.current, forKey: "lastNote")
    }

    // MARK: - Window

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // Appears and disappears at once, with no fade AppKit might add.
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        // Added after creating the panel, which keeps its frame: with this in the style mask, the
        // content rect it's created with would cover the title bar too, making it shorter.
        panel.styleMask.insert(.fullSizeContentView)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 160)
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        // Set explicitly, so clicks where the background is clear reach the panel, not the app behind.
        panel.ignoresMouseEvents = false
        bridge.webView.setValue(false, forKey: "drawsBackground")
        panel.contentView = background(behind: bridge.webView)
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

        // The note's name, centered; clicking it renames the note.
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.isEditable = true
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.usesSingleLineMode = true
        titleField.focusRingType = .none
        titleField.delegate = self
        titleField.toolTip = "Click to rename"
        titleField.setAccessibilityLabel("Note name")
        // An editable field has no width of its own, so it's sized to its name.
        titleWidth = titleField.widthAnchor.constraint(equalToConstant: 120)
        // Left of the name, whether its text is saved; clicking it opens the history. The icon
        // keeps one width for every symbol, so the name doesn't move when the symbol changes.
        saveIcon.title = ""
        saveIcon.isBordered = false
        saveIcon.imagePosition = .imageOnly
        saveIcon.imageScaling = .scaleNone
        saveIcon.target = self
        saveIcon.action = #selector(historyClicked)
        saveIcon.onPointing = { [weak self] in self?.showSaveState() }
        // The icon goes over the name's field, which reaches under it when the name is short.
        for view in [titleField, saveIcon] {
            view.translatesAutoresizingMaskIntoConstraints = false
            titleView.addSubview(view)
        }
        saveIconWidth = saveIcon.widthAnchor.constraint(equalToConstant: uiFontSize)
        saveIconGap = titleField.leadingAnchor.constraint(equalTo: saveIcon.trailingAnchor)
        NSLayoutConstraint.activate([
            titleWidth, saveIconWidth, saveIconGap,
            // The icon's frame reaches past the symbol, and stays in the item.
            saveIcon.leadingAnchor.constraint(equalTo: titleView.leadingAnchor, constant: HistoryButton.margin),
            saveIcon.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            titleField.trailingAnchor.constraint(equalTo: titleView.trailingAnchor),
            titleField.topAnchor.constraint(equalTo: titleView.topAnchor),
            titleField.bottomAnchor.constraint(equalTo: titleView.bottomAnchor),
        ])
        let browse = toolbarButton("list.bullet", "Browse Notes (⌘P)", #selector(browseClicked))
        let right = [
            toolbarButton("square.and.pencil", "New Note (⌘N)", #selector(newNoteClicked)),
            toolbarButton("folder", "Open Notes Folder (⌘O)", #selector(openFolderClicked)),
        ]
        buttons = [browse] + right
        browseView.addArrangedSubview(browse)
        // The spacing the toolbar gave them before macOS 26, which spaces separate items for glass.
        buttonsView.spacing = 12
        for button in right { buttonsView.addArrangedSubview(button) }
        applyUIFontSize()

        // A toolbar sizes the title bar to the title and buttons and keeps the traffic lights
        // centered beside them; the compact style keeps the space above and below small.
        let toolbar = NSToolbar(identifier: "notepanel")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Item.title]
        panel.toolbar = toolbar
        panel.toolbarStyle = .unifiedCompact

        // The panel keeps the size the user gives it; nothing resizes it to fit a note.
        defaultSize = panel.frame.size
        if !panel.setFrameUsingName(Self.frameName) { panel.center() }
        panel.setFrameAutosaveName(Self.frameName)
    }

    /// The switcher's window floats with the panel and takes its keys. The page draws the
    /// switcher's corners as a row's corners and the edge around them, so the chosen row's frame
    /// fits a bottom corner whole; the glass and the window's shadow follow them.
    private func configureSide() {
        side.isFloatingPanel = true
        side.level = .floating
        side.hidesOnDeactivate = false
        side.animationBehavior = .none
        side.collectionBehavior = panel.collectionBehavior
        side.isOpaque = false
        side.backgroundColor = .clear
        side.hasShadow = true
        side.isReleasedWhenClosed = false
        side.commands = panel.commands
        side.onZoom = panel.onZoom
        sideBridge.webView.setValue(false, forKey: "drawsBackground")
        side.contentView = background(behind: sideBridge.webView, cornerRadius: 7)
    }

    /// tinycast's background: glass (a blur before macOS 26) under a scrim. It runs under the
    /// title bar too, while the page starts below the title bar, where it was before.
    private func background(behind page: NSView, cornerRadius: CGFloat = 0) -> NSView {
        let glass = Self.makeGlass(cornerRadius: cornerRadius)
        let scrim = NSBox()
        scrim.boxType = .custom
        scrim.titlePosition = .noTitle
        scrim.borderWidth = 0
        scrim.cornerRadius = cornerRadius
        scrim.fillColor = Self.scrimColor(solid: 0)
        backdrops.append((glass, scrim))
        let view = NSView()
        for backdrop in [glass, scrim] {
            backdrop.frame = view.bounds
            backdrop.autoresizingMask = [.width, .height]
            view.addSubview(backdrop)
        }
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        return view
    }

    private static func makeGlass(cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            if cornerRadius > 0 { glass.cornerRadius = cornerRadius }
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .popover
        // The app is never active, so the blur would otherwise always look inactive.
        blur.state = .active
        if cornerRadius > 0 {
            // A rounded square, stretched between its corners.
            let size = 2 * cornerRadius + 1
            let mask = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
                return true
            }
            mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
            mask.resizingMode = .stretch
            blur.maskImage = mask
        }
        return blur
    }

    /// tinycast's scrim is black at 40% in dark mode and white at 55% in light mode. `solid`,
    /// from 0 to 1, takes it from there to fully opaque.
    private static func scrimColor(solid: Double) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let alpha = dark ? 0.4 : 0.55
            return (dark ? NSColor.black : .white).withAlphaComponent(CGFloat(alpha + (1 - alpha) * solid))
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.browse, .flexibleSpace, Item.title, .flexibleSpace, Item.buttons]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Item.browse: item.view = browseView
        case Item.title: item.view = titleView
        case Item.buttons: item.view = buttonsView
        default: return nil
        }
        // From macOS 26 every toolbar item sits on glass, which put the name and the buttons in capsules.
        item.isBordered = false
        return item
    }

    private func toolbarButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = ToolbarButton(title: "", target: self, action: action)
        button.isBordered = false
        // Centered in the button's frame, which is wider than the symbol.
        button.imagePosition = .imageOnly
        button.identifier = NSUserInterfaceItemIdentifier(symbol)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    /// Sizes the title and the toolbar's symbols by the interface text size.
    private func applyUIFontSize() {
        titleField.font = .systemFont(ofSize: uiFontSize, weight: .semibold)
        let configuration = NSImage.SymbolConfiguration(pointSize: uiFontSize + 1, weight: .regular)
        for button in buttons {
            guard let symbol = button.identifier?.rawValue else { continue }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.toolTip)?
                .withSymbolConfiguration(configuration)
        }
        saveIconWidth.constant = uiFontSize
        showSaveState()
        sizeTitle()
    }

    /// A dashed circle while the text isn't saved yet, a checked circle once it is, and a red
    /// warning if saving failed (the footer says why). As the history button, it shows a clock
    /// when pointed at, but not over a failed save, whose warning stays in sight. While the
    /// history is open, the clock is in the accent color.
    private func showSaveState() {
        let state = store.saveState
        let (symbol, label): (String, String) =
            switch state {
            case .saved: ("checkmark.circle", "Saved")
            case .editing: ("circle.dashed", "Not saved yet")
            case .failed: ("exclamationmark.triangle", "Couldn’t save")
            }
        let pointing = saveIcon.pointing
        let clock = historyShown || (pointing && state != .failed)
        saveIcon.image = NSImage(systemSymbolName: clock ? "clock.arrow.circlepath" : symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: uiFontSize, weight: .regular, scale: .small))
        saveIcon.contentTintColor =
            historyShown ? .controlAccentColor
            : state == .failed ? .systemRed
            : pointing ? .labelColor : .secondaryLabelColor
        saveIcon.backdrop =
            historyShown ? NSColor.controlAccentColor.withAlphaComponent(0.2)
            : pointing ? .quaternaryLabelColor : nil
        saveIcon.toolTip = historyShown ? "Close History (⌘Y)" : "\(label) · Show History (⌘Y)"
        saveIcon.setAccessibilityLabel(historyShown ? "Close History" : "Show History")
        saveIcon.setAccessibilityValue(label)
    }

    @objc private func historyClicked() { toggleHistory() }
    @objc private func newNoteClicked() { newNote() }
    @objc private func browseClicked() { showSwitcher(find: false, toggle: true) }
    @objc private func openFolderClicked() { openFolder() }

    // MARK: - The title

    private func updateTitle() {
        let name = store.current ?? ""
        panel.title = name
        guard titleField.currentEditor() == nil else { return }
        titleField.stringValue = name
        sizeTitle()
    }

    /// Leaves room on both sides for the buttons (wider than the traffic lights), so a long name
    /// stays centered and ends in "…" instead of pushing the buttons into the overflow menu.
    private func sizeTitle(panelWidth: CGFloat? = nil) {
        let text = titleField.attributedStringValue.size().width
        let width = (text + 16).rounded(.up)
        let gap: CGFloat = 5
        // shortcut: margins taken from one screenshot (about 20 pt for the toolbar's edge and a gap
        // before the title); measure the laid-out buttons if another macOS sets them wider.
        // The left side has the traffic lights and the switcher's button, taken as 78 pt more than
        // the button; the name gets what the wider side leaves.
        let buttonsWidth = max(buttonsView.fittingSize.width + 20, browseView.fittingSize.width + 78)
        let room = (panelWidth ?? panel.frame.width) - 2 * buttonsWidth - HistoryButton.margin - saveIconWidth.constant - gap
        titleWidth.constant = max(0, min(max(width, 80), 360, room))
        // The name is centered in its field, so the icon moves in over the space left of it and
        // stays `gap` from the text, also when a short name leaves the field wider than the text.
        saveIconGap.constant = gap - max(0, titleWidth.constant - text) / 2
    }

    /// Ends typing in the title before another note opens, so the name goes to the note it was
    /// typed for. Otherwise ending later would try to give that name to the newly opened note.
    private func finishTitle() {
        if titleField.currentEditor() != nil { focusEditor() }
    }

    /// The note takes the typing, also when the switcher's window had it.
    private func focusEditor() {
        if panel.isVisible { panel.makeKey() }
        panel.makeFirstResponder(bridge.webView)
        bridge.send("focus", "")
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            titleField.abortEditing()
            updateTitle()
            focusEditor()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            focusEditor()  // Ends editing, which renames the note.
            return true
        }
        return false
    }

    /// A name typed here is the user's own, so the file stops following the note's first line.
    func controlTextDidEndEditing(_ notification: Notification) {
        if let current = store.current, titleField.stringValue != current {
            rename(current, to: titleField.stringValue)
        }
        // Set directly: the field may still count as editing here. A refused name reverts.
        titleField.stringValue = store.current ?? ""
        sizeTitle()
    }
}

/// The note's name, with an undo history of its own. The panel's shared history may also hold
/// WebKit's records of typing in the note, which ⌘Z in the name must not undo. The field editor
/// asks its delegate, the field being edited, for the history to use.
/// A toolbar button that also takes clicks a little around its symbol. Its frame reaches past the
/// alignment rect the stack lays out, so the symbol and the row keep their places; 6 pt is half the
/// spacing between the buttons, so neighbors meet without overlapping.
private final class ToolbarButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6) }
    // The symbol's size, as before the insets, whatever AppKit makes of them.
    override var intrinsicContentSize: NSSize { cell?.cellSize ?? super.intrinsicContentSize }
}

/// The save icon, which is also the history button. Like a toolbar button, it takes clicks a little
/// around its symbol; `margin` is less than the 5 pt gap to the name, so clicking the name still
/// renames the note.
private final class HistoryButton: NSButton {
    static let margin: CGFloat = 4
    var onPointing: () -> Void = {}
    var pointing = false {
        didSet { if pointing != oldValue { onPointing() } }
    }
    /// Drawn behind the symbol.
    var backdrop: NSColor? {
        didSet { needsDisplay = true }
    }
    private lazy var area = NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: Self.margin, left: Self.margin, bottom: Self.margin, right: Self.margin)
    }
    override var intrinsicContentSize: NSSize { cell?.cellSize ?? super.intrinsicContentSize }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !trackingAreas.contains(area) { addTrackingArea(area) }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointing = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pointing = false
    }

    /// A rounded square 2 pt wider than the symbol on each side, which keeps within the name's height.
    override func draw(_ dirtyRect: NSRect) {
        if let backdrop {
            let side = bounds.width - Self.margin
            backdrop.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side),
                xRadius: 5, yRadius: 5
            ).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Passes on clicks on the parts of the buttons' frames that reach outside the row.
private final class ButtonRow: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return arrangedSubviews.first { $0.frame.contains(local) } ?? super.hitTest(point)
    }
}

private final class NameField: NSTextField {
    private let history = UndoManager()

    @objc(undoManagerForTextView:)
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The display's UUID, which lasts across restarts and reconnections, unlike its ID. Mirrored
    /// displays all go by the one they mirror, whichever of them this screen stands for.
    var displayKey: String? {
        guard let id = displayID else { return nil }
        let mirrored = CGDisplayMirrorsDisplay(id)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(mirrored == kCGNullDirectDisplay ? id : mirrored)
        else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }
}
