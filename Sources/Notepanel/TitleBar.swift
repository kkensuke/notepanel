import AppKit
import NotepanelCore

/// The panel's title bar, a toolbar: the switcher's button at the left, the note's name in the
/// middle with the save icon left of it, and the New Note and Open Folder buttons at the right.
@MainActor
final class TitleBar: NSObject, NSToolbarDelegate, NSTextFieldDelegate {
    /// What the buttons do, and renaming the open note to what was typed. The controller sets them.
    var onHistory: () -> Void = {}
    var onBrowse: () -> Void = {}
    var onNewNote: () -> Void = {}
    var onOpenFolder: () -> Void = {}
    var onRename: (_ name: String, _ proposed: String) -> Void = { _, _ in }
    /// Gives the note the keys, which also ends typing in the name.
    var focusEditor: () -> Void = {}
    /// Whether the page shows the history, as it last said.
    var historyShown = false {
        didSet { showSaveState() }
    }
    /// The interface text size, which the name and the symbols follow.
    var uiFontSize: CGFloat = 15 {
        didSet { if uiFontSize != oldValue { applyUIFontSize() } }
    }

    private let panel: NSPanel
    private let store: NoteStore
    private let titleField: NSTextField = NameField(string: "")
    private var titleWidth: NSLayoutConstraint!
    /// The save icon and the name, as one toolbar item.
    private let titleView = NSView()
    /// Also the history button.
    private let saveIcon = HistoryButton()
    private var saveIconWidth: NSLayoutConstraint!
    private var saveIconGap: NSLayoutConstraint!
    private var buttons: [NSButton] = []
    /// The buttons at the right, as one toolbar item.
    private let buttonsView = ButtonRow()
    /// The switcher's button, at the left, over the switcher.
    private let browseView = ButtonRow()

    private enum Item {
        static let browse = NSToolbarItem.Identifier("browse")
        static let title = NSToolbarItem.Identifier("title")
        static let buttons = NSToolbarItem.Identifier("buttons")
    }

    init(panel: NSPanel, store: NoteStore) {
        self.panel = panel
        self.store = store
        super.init()
    }

    /// Sets up the name, the save icon and the buttons, and gives the panel the toolbar with them.
    func install() {
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
    func showSaveState() {
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

    /// The pointer leaves the icon with the panel, and no exit says so.
    func pointerLeft() {
        saveIcon.pointing = false
    }

    @objc private func historyClicked() { onHistory() }
    @objc private func newNoteClicked() { onNewNote() }
    @objc private func browseClicked() { onBrowse() }
    @objc private func openFolderClicked() { onOpenFolder() }

    // MARK: - The name

    func updateTitle() {
        let name = store.current ?? ""
        panel.title = name
        guard titleField.currentEditor() == nil else { return }
        titleField.stringValue = name
        sizeTitle()
    }

    /// Leaves room on both sides for the buttons (wider than the traffic lights), so a long name
    /// stays centered and ends in "…" instead of pushing the buttons into the overflow menu.
    func sizeTitle(panelWidth: CGFloat? = nil) {
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
    func finishTitle() {
        if titleField.currentEditor() != nil { focusEditor() }
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
            onRename(current, titleField.stringValue)
        }
        // Set directly: the field may still count as editing here. A refused name reverts.
        titleField.stringValue = store.current ?? ""
        sizeTitle()
    }
}
