import AppKit

/// The switcher's window, at the panel's left, with the same page as the note's in a web view of
/// its own. While the switcher is up, the window is the panel's child, which moves with it.
@MainActor
final class SwitcherWindow {
    /// Borderless, so its shape is its glass's.
    let window = NotePanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let bridge: EditorBridge
    let backdrop: Backdrop
    /// Whether the switcher's page shows the switcher, as it last said.
    private(set) var isShown = false
    /// How tall the window may be, as its page says: ten rows under the search field.
    var maxHeight = CGFloat.greatestFiniteMagnitude
    private let panel: NotePanel
    /// The note's page in the panel, which the window goes beside.
    private let notePage: NSView
    /// The switcher's width, in points. Dragging the switcher's left edge changes it, and it's
    /// kept when the switcher closes.
    private var width = CGFloat(
        max(Prefs.minSideWidth, UserDefaults.standard.object(forKey: "sideWidth") as? Double ?? Prefs.defaultSideWidth))
    /// Where the panel was and where it went, when it moved right to make room for the switcher.
    private var shift: (from: NSRect, to: NSRect)?

    init(panel: NotePanel, notePage: NSView) {
        self.panel = panel
        self.notePage = notePage
        let bridge = EditorBridge()
        self.bridge = bridge
        bridge.webView.setValue(false, forKey: "drawsBackground")
        backdrop = Backdrop(behind: bridge.webView, cornerRadius: 7)
    }

    /// The window floats with the panel and takes its keys, so it's set up once the panel is. The
    /// page draws the switcher's corners as a row's corners and the edge around them, so the
    /// chosen row's frame fits a bottom corner whole; the glass and the window's shadow follow them.
    func configure() {
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.collectionBehavior = panel.collectionBehavior
        window.isOpaque = false
        window.backgroundColor = .clear
        // As the key window, it would get a shadow drawn round its frame's square corners, not
        // the glass's round ones.
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.commands = panel.commands
        window.onZoom = panel.onZoom
        window.contentView = backdrop.view
    }

    var isKey: Bool { window.isKeyWindow }

    /// Where the display has no room at the panel's left, the panel moves right while the switcher
    /// is up, and back when it closes, unless it was moved meanwhile.
    /// shortcut: checked only as the switcher opens; a panel moved to the display's left edge
    /// while it's up, by hand or by ⌃⌘M, takes the switcher off the display.
    func open() {
        isShown = true
        let room = roomLeft
        if room < width {
            let from = panel.frame
            panel.setFrameOrigin(NSPoint(x: from.minX + width - room, y: from.minY))
            shift = (from, panel.frame)
        }
    }

    /// Takes the window away, keeps its width, and puts the panel back if it moved to make room.
    func close() {
        isShown = false
        panel.removeChildWindow(window)
        window.orderOut(nil)
        UserDefaults.standard.set(Double(width), forKey: "sideWidth")
        if let shift, panel.frame == shift.to { panel.setFrame(shift.from, display: true) }
        shift = nil
    }

    /// The window goes at the panel's left, flush with it, from under the title bar down to the
    /// panel's bottom, or as far as its page asks.
    func place() {
        let page = panel.convertToScreen(notePage.convert(notePage.bounds, to: nil))
        let height = min(page.height, maxHeight)
        window.setFrame(
            NSRect(x: page.minX - width, y: page.maxY - height, width: width, height: height), display: true)
    }

    func attach() {
        place()
        if window.parent == nil { panel.addChildWindow(window, ordered: .above) }
        window.orderFront(nil)
    }

    /// Typing goes to the switcher's page, where it put the focus.
    func focus() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(bridge.webView)
    }

    /// The width the page asks for as its left edge is dragged, as far as the display goes to the left.
    func setWidth(_ asked: CGFloat) {
        width = max(CGFloat(Prefs.minSideWidth), min(asked, roomLeft))
        place()
    }

    /// How far the display goes at the panel's left. With the panel's display unknown, there's no limit.
    private var roomLeft: CGFloat {
        guard let screen = panel.screen else { return .greatestFiniteMagnitude }
        return panel.frame.minX - screen.visibleFrame.minX
    }
}
