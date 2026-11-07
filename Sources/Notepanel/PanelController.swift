import AppKit
import NotepanelCore

/// Shows and hides the note panel, and connects it to the note store and the editor page.
@MainActor
final class PanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    let store: NoteStore
    var openSettings: () -> Void = {}

    private let panel: NotePanel
    private let bridge = EditorBridge()
    private let titleField = NSTextField(string: "")
    private var previousApp: NSRunningApplication?
    private var contentHeight: CGFloat = 0
    private var maxHeight: CGFloat = 640
    private var options: NSDictionary = [:]
    /// Old names of renamed notes, so text the page sent under an old name still lands.
    private var renamed: [String: String] = [:]

    private static let frameName = "Note Panel"
    private static let minHeight: CGFloat = 120

    init(store: NoteStore) {
        self.store = store
        panel = NotePanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()
        configurePanel()
        store.onStatus = { [weak self] message in self?.bridge.send("status", message ?? "") }
        store.onConflict = { [weak self] from, to in
            self?.noteRenamed(from, to)
            self?.updateTitle()
        }
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
                updateTitle()
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

    func setOptions(fontFamily: String, fontSize: Double, maxHeight: Double) {
        let new: NSDictionary = ["fontFamily": fontFamily, "fontSize": fontSize]
        if new != options {
            options = new
            bridge.send("options", new)
        }
        if CGFloat(maxHeight) != self.maxHeight {
            self.maxHeight = CGFloat(maxHeight)
            fitHeight()
        }
    }

    // MARK: - Messages from the page

    private func handle(_ type: String, _ body: [String: Any]) {
        switch type {
        case "ready":
            // Also after the page reloads, so it gets its options and a note again.
            bridge.send("options", options)
            openSomeNote()
        case "changed":
            // The page sends the whole text, so text sent under an old name is still current.
            guard let sent = body["id"] as? String, (renamed[sent] ?? sent) == store.current,
                let text = body["text"] as? String
            else { return }
            store.edit(text)
            updateTitle()
        case "height":
            guard let height = body["height"] as? Double else { return }
            contentHeight = CGFloat(height)
            fitHeight()
        case "select":
            if let id = body["id"] as? String { open(id) }
        case "trash":
            if let id = body["id"] as? String { trash(id) }
        case "rename":
            guard let from = body["from"] as? String, let to = body["to"] as? String else { return }
            rename(from, to: to)
            updateTitle()
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

    private func rename(_ old: String, to proposed: String) {
        do {
            let new = try store.rename(old, to: proposed)
            if new != old { noteRenamed(old, new) }
        } catch NoteStoreError.exists {
            store.notify("A note named “\(proposed.trimmingCharacters(in: .whitespaces))” already exists.")
        } catch NoteStoreError.invalidName {
            store.notify("A name can’t be empty, start with a period, or contain “/” or “:”.")
        } catch {
            store.notify("Couldn’t rename “\(old)”: \(error.localizedDescription)")
        }
    }

    private func trash(_ name: String) {
        do {
            try store.trash(name)
        } catch {
            store.notify("Couldn’t move “\(name)” to the Trash: \(error.localizedDescription)")
            return
        }
        bridge.send("trashed", name)
        if store.current == nil { openSomeNote(keepSwitcher: true) }
        bridge.send("notes", notesForSwitcher())
    }

    private func toggleSwitcher() {
        bridge.send("switcher", ["notes": notesForSwitcher(), "force": false])
    }

    // shortcut: reads every note on each open of the switcher; fine for hundreds of notes.
    private func notesForSwitcher() -> [[String: Any]] {
        store.list().map { note in
            let text = note.name == store.current ? store.text : (store.read(note.name) ?? "")
            return [
                "id": note.name,
                "title": displayTitle(name: note.name, text: text),
                "modified": note.modified.timeIntervalSince1970 * 1000,
                "text": text,
            ]
        }
    }

    private func noteRenamed(_ old: String, _ new: String) {
        renamed[old] = new
        for (from, to) in renamed where to == old { renamed[from] = new }
        bridge.send("renamed", ["from": old, "to": new])
        rememberCurrent()
    }

    private func rememberCurrent() {
        UserDefaults.standard.set(store.current, forKey: "lastNote")
    }

    // MARK: - Window

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .textBackgroundColor
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 280, height: Self.minHeight)
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.commands = [
            "n": { [weak self] in self?.newNote() },
            "p": { [weak self] in self?.toggleSwitcher() },
            "w": { [weak self] in self?.hide() },
            "o": { [weak self] in self?.openFolder() },
            ",": { [weak self] in self?.openSettings() },
            // Quitting is in the menu bar icon's menu, so it can't happen by accident while typing.
            "q": {},
        ]

        let content = NSView()
        let bar = titleBar()
        for view in [bar, bridge.webView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        panel.contentView = content
        // The bar fills the transparent title bar; the page starts below it.
        let below = (panel.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? content.topAnchor
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: below),
            bridge.webView.topAnchor.constraint(equalTo: below),
            bridge.webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bridge.webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bridge.webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        if !panel.setFrameUsingName(Self.frameName) { panel.center() }
        panel.setFrameAutosaveName(Self.frameName)
    }

    /// The note's name, which can be clicked to rename it, and the New, Browse and Folder buttons.
    private func titleBar() -> NSView {
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.isEditable = true
        titleField.font = .titleBarFont(ofSize: 0)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.usesSingleLineMode = true
        titleField.focusRingType = .none
        titleField.delegate = self
        titleField.toolTip = "Click to rename"
        titleField.setAccessibilityLabel("Note name")

        let buttons = NSStackView(views: [
            barButton("square.and.pencil", "New Note (⌘N)", #selector(newNoteClicked)),
            barButton("list.bullet", "Browse Notes (⌘P)", #selector(browseClicked)),
            barButton("folder", "Open Notes Folder (⌘O)", #selector(openFolderClicked)),
        ])
        buttons.spacing = 4

        let bar = NSView()
        for view in [titleField, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(view)
        }
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            // Clear of the traffic lights.
            titleField.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 78),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            titleField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            buttons.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    private func barButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    @objc private func newNoteClicked() { newNote() }
    @objc private func browseClicked() { toggleSwitcher() }
    @objc private func openFolderClicked() { openFolder() }

    private func fitHeight() {
        guard contentHeight > 0, let screen = panel.screen ?? NSScreen.main else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let chrome = panel.frame.height - bridge.webView.frame.height
        let frame = fittedFrame(
            panel.frame, height: chrome + contentHeight, minHeight: Self.minHeight, maxHeight: maxHeight,
            in: screen.visibleFrame)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    // MARK: - Renaming from the title bar

    private func updateTitle() {
        guard let name = store.current, titleField.currentEditor() == nil else { return }
        titleField.stringValue = displayTitle(name: name, text: store.text)
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

    func controlTextDidEndEditing(_ notification: Notification) {
        if let old = store.current, titleField.stringValue != displayTitle(name: old, text: store.text) {
            rename(old, to: titleField.stringValue)
        }
        updateTitle()
    }
}
