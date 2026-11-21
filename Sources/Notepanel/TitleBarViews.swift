import AppKit

// The title bar's own views: the toolbar's buttons, the save icon, and the note's name.

/// A toolbar button that also takes clicks a little around its symbol. Its frame reaches past the
/// alignment rect the stack lays out, so the symbol and the row keep their places; 6 pt is half the
/// spacing between the buttons, so neighbors meet without overlapping.
final class ToolbarButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6) }
    // The symbol's size, as before the insets, whatever AppKit makes of them.
    override var intrinsicContentSize: NSSize { cell?.cellSize ?? super.intrinsicContentSize }
}

/// The save icon, which is also the history button. Like a toolbar button, it takes clicks a little
/// around its symbol; `margin` is less than the 5 pt gap to the name, so clicking the name still
/// renames the note.
final class HistoryButton: NSButton {
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
final class ButtonRow: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return arrangedSubviews.first { $0.frame.contains(local) } ?? super.hitTest(point)
    }
}

/// The note's name, with an undo history of its own. The panel's shared history may also hold
/// WebKit's records of typing in the note, which ⌘Z in the name must not undo. The field editor
/// asks its delegate, the field being edited, for the history to use.
final class NameField: NSTextField {
    private let history = UndoManager()

    @objc(undoManagerForTextView:)
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}
