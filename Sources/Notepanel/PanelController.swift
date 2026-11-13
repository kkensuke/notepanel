import AppKit
import NotepanelCore

/// Shows and hides the note panel, and connects it to the note store and the editor page.
@MainActor
final class PanelController: NSObject, NSWindowDelegate, NSToolbarDelegate, NSTextFieldDelegate {
    let store: NoteStore
    var toggleSettings: () -> Void = {}

    private let panel: NotePanel
    private let bridge = EditorBridge()
    /// The background under the page: glass, with a scrim over it.
    private let glass = PanelController.makeGlass()
    private let scrim = NSBox()
    private var backgroundOpacity: Double?
    private let titleField = NSTextField(string: "")
    private var titleWidth: NSLayoutConstraint!
    /// The save icon and the name, as one toolbar item.
    private let titleView = NSView()
    private let saveIcon = NSImageView()
    private var saveIconWidth: NSLayoutConstraint!
    private var saveIconGap: NSLayoutConstraint!
    private var buttons: [NSToolbarItem.Identifier: NSButton] = [:]
    private var previousApp: NSRunningApplication?
    private var uiFontSize: CGFloat = 15
    private var options: NSDictionary = [:]
    /// Old names of renamed notes, so text the page sent under an old name still lands.
    private var renamed: [String: String] = [:]

    private static let frameName = "Note Panel"

    private enum Item {
        static let title = NSToolbarItem.Identifier("title")
        static let new = NSToolbarItem.Identifier("new")
        static let browse = NSToolbarItem.Identifier("browse")
        static let folder = NSToolbarItem.Identifier("folder")
    }

    init(store: NoteStore) {
        self.store = store
        panel = NotePanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()
        configurePanel()
        store.onStatus = { [weak self] message in self?.bridge.send("status", message ?? "") }
        store.onRenamed = { [weak self] from, to in self?.noteRenamed(from, to) }
        store.onSaveState = { [weak self] state in self?.showSaveState(state) }
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
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        focusEditor()
    }

    /// Returns focus to the app that was in front, unless the user has moved on to another one.
    /// Saving comes after the panel is gone, so writing the file doesn't hold it on screen.
    func hide() {
        if panel.isVisible {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let movedOn = front != NSRunningApplication.current.processIdentifier && front != previousApp?.processIdentifier
            panel.orderOut(nil)
            if !movedOn { _ = previousApp?.activate(options: []) }
        }
        store.flush()
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

    func windowDidResize(_ notification: Notification) {
        sizeTitle()
    }

    // MARK: - Settings

    func setFolder(_ folder: URL) {
        guard folder.standardizedFileURL != store.folder.standardizedFileURL else { return }
        finishTitle()
        store.setFolder(folder)
        UserDefaults.standard.removeObject(forKey: "lastNote")
        openSomeNote()
    }

    func setOptions(fontFamily: String, fontSize: Double, uiFontSize: Double, showWhitespace: Bool, indentSize: Int) {
        let new: NSDictionary = [
            "fontFamily": fontFamily, "fontSize": fontSize, "uiFontSize": uiFontSize,
            "showWhitespace": showWhitespace, "indentSize": indentSize,
        ]
        guard new != options else { return }
        options = new
        bridge.send("options", new)
        if CGFloat(uiFontSize) != self.uiFontSize {
            self.uiFontSize = CGFloat(uiFontSize)
            applyUIFontSize()
        }
    }

    func setNoteShortcuts(next: Shortcut?, previous: Shortcut?) {
        var shortcuts: [(Shortcut, () -> Void)] = []
        if let next { shortcuts.append((next, { [weak self] in self?.cycle(1) })) }
        if let previous { shortcuts.append((previous, { [weak self] in self?.cycle(-1) })) }
        panel.shortcuts = shortcuts
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
        glass.alphaValue = fade
        scrim.alphaValue = fade
        scrim.fillColor = Self.scrimColor(solid: max(0, (opacity - middle) / (1 - middle)))
        // With nothing behind the text, the shadow would outline the letters.
        panel.hasShadow = fade > 0
        panel.invalidateShadow()
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
        case "select":
            if let id = body["id"] as? String { open(id) }
        case "trash":
            if let id = body["id"] as? String { confirmTrash(id) }
        case "pin":
            if let id = body["id"] as? String { togglePin(id) }
        case "orderPins":
            if let ids = body["ids"] as? [String] { orderPins(ids) }
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
            hide()
        default:
            break
        }
    }

    // MARK: - Notes

    @discardableResult
    private func open(_ name: String, keepSwitcher: Bool = false) -> Bool {
        finishTitle()
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
        finishTitle()
        do {
            let name = try store.create()
            bridge.send("open", ["id": name, "text": "", "keep": keepSwitcher])
            rememberCurrent()
            updateTitle()
        } catch {
            store.notify("Couldn’t create a note: \(error.localizedDescription)")
        }
    }

    /// Opens the next or previous note in the switcher's order, wrapping around.
    private func cycle(_ step: Int) {
        let names = orderedNotes().map(\.name)
        guard names.count > 1, let current = store.current, let index = names.firstIndex(of: current) else { return }
        open(names[(index + step + names.count) % names.count])
    }

    /// Every rename comes through here, from the store: the user's, a file following its
    /// first line, and a conflict copy.
    private func noteRenamed(_ old: String, _ new: String) {
        renamed[old] = new
        for (from, to) in renamed where to == old { renamed[from] = new }
        var pins = Prefs.pinned(in: store.folder)
        if let index = pins.firstIndex(of: old) {
            pins[index] = new
            Prefs.setPinned(pins, in: store.folder)
        }
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
        Prefs.setPinned(Prefs.pinned(in: store.folder).filter { $0 != trashed }, in: store.folder)
        bridge.send("trashed", trashed)
        if store.current == nil { openSomeNote(keepSwitcher: true) }
        bridge.send("notes", notesForSwitcher())
    }

    private func togglePin(_ name: String) {
        var pins = Prefs.pinned(in: store.folder)
        if let index = pins.firstIndex(of: name) { pins.remove(at: index) } else { pins.append(name) }
        Prefs.setPinned(pins, in: store.folder)
        bridge.send("notes", notesForSwitcher())
    }

    /// The page sends the pinned notes it shows, in their new order. Pins whose file is missing
    /// aren't shown, so they keep their place after the others.
    private func orderPins(_ ids: [String]) {
        let pins = Prefs.pinned(in: store.folder)
        guard Set(ids).count == ids.count, Set(ids).isSubset(of: pins) else { return }
        Prefs.setPinned(ids + pins.filter { !ids.contains($0) }, in: store.folder)
        bridge.send("notes", notesForSwitcher())
    }

    /// Cmd-1 to Cmd-9 open the first to ninth pinned note.
    private func openPinned(_ number: Int) {
        let pins = Set(Prefs.pinned(in: store.folder))
        let pinned = orderedNotes().filter { pins.contains($0.name) }
        if pinned.indices.contains(number - 1) { open(pinned[number - 1].name) }
    }

    private func toggleSwitcher() {
        bridge.send("switcher", ["notes": notesForSwitcher(), "force": false])
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
        // Left of the name, whether its text is saved. The icon keeps one width for every
        // symbol, so the name doesn't move when the symbol changes.
        saveIcon.imageScaling = .scaleNone
        for view in [saveIcon, titleField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            titleView.addSubview(view)
        }
        saveIconWidth = saveIcon.widthAnchor.constraint(equalToConstant: uiFontSize)
        saveIconGap = titleField.leadingAnchor.constraint(equalTo: saveIcon.trailingAnchor)
        NSLayoutConstraint.activate([
            titleWidth, saveIconWidth, saveIconGap,
            saveIcon.leadingAnchor.constraint(equalTo: titleView.leadingAnchor),
            saveIcon.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            titleField.trailingAnchor.constraint(equalTo: titleView.trailingAnchor),
            titleField.topAnchor.constraint(equalTo: titleView.topAnchor),
            titleField.bottomAnchor.constraint(equalTo: titleView.bottomAnchor),
        ])
        buttons = [
            Item.new: toolbarButton("square.and.pencil", "New Note (⌘N)", #selector(newNoteClicked)),
            Item.browse: toolbarButton("list.bullet", "Browse Notes (⌘P)", #selector(browseClicked)),
            Item.folder: toolbarButton("folder", "Open Notes Folder (⌘O)", #selector(openFolderClicked)),
        ]
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
        if !panel.setFrameUsingName(Self.frameName) { panel.center() }
        panel.setFrameAutosaveName(Self.frameName)
    }

    /// tinycast's background: glass (a blur before macOS 26) under a scrim. It runs under the
    /// title bar too, while the page starts below the title bar, where it was before.
    private func background(behind page: NSView) -> NSView {
        scrim.boxType = .custom
        scrim.titlePosition = .noTitle
        scrim.borderWidth = 0
        scrim.fillColor = Self.scrimColor(solid: 0)
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

    private static func makeGlass() -> NSView {
        if #available(macOS 26, *) { return NSGlassEffectView() }
        let blur = NSVisualEffectView()
        blur.material = .popover
        // The app is never active, so the blur would otherwise always look inactive.
        blur.state = .active
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
            item.view = titleView
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

    /// Sizes the title and the toolbar's symbols by the interface text size.
    private func applyUIFontSize() {
        titleField.font = .systemFont(ofSize: uiFontSize, weight: .semibold)
        let configuration = NSImage.SymbolConfiguration(pointSize: uiFontSize + 1, weight: .regular)
        for button in buttons.values {
            guard let symbol = button.identifier?.rawValue else { continue }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.toolTip)?
                .withSymbolConfiguration(configuration)
        }
        saveIconWidth.constant = uiFontSize
        showSaveState(store.saveState)
        sizeTitle()
    }

    /// A dashed circle while the text isn't saved yet, a checked circle once it is, and a red
    /// warning if saving failed (the footer says why).
    private func showSaveState(_ state: SaveState) {
        let (symbol, label): (String, String) =
            switch state {
            case .saved: ("checkmark.circle", "Saved")
            case .editing: ("circle.dashed", "Not saved yet")
            case .failed: ("exclamationmark.triangle", "Couldn’t save")
            }
        saveIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: uiFontSize, weight: .regular, scale: .small))
        saveIcon.contentTintColor = state == .failed ? .systemRed : .secondaryLabelColor
        saveIcon.toolTip = label
    }

    @objc private func newNoteClicked() { newNote() }
    @objc private func browseClicked() { toggleSwitcher() }
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
    private func sizeTitle() {
        let text = titleField.attributedStringValue.size().width
        let width = (text + 16).rounded(.up)
        let gap: CGFloat = 5
        // shortcut: spacing taken from one screenshot (about 12 pt per button, plus 8 pt to keep a
        // gap before the title); measure the laid-out buttons if another macOS spaces them wider.
        let buttonsWidth = buttons.values.map { $0.fittingSize.width + 12 }.reduce(8, +)
        let room = panel.frame.width - 2 * buttonsWidth - saveIconWidth.constant - gap
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

    private func focusEditor() {
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
