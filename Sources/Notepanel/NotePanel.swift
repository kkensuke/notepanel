import AppKit

/// A floating panel that takes keys without activating the app, so the app underneath stays active.
final class NotePanel: NSPanel {
    /// Cmd-key commands, by lowercased character. They don't repeat while the key is held.
    var commands: [String: () -> Void] = [:]
    /// Cmd-plus and Cmd-minus (+1 and -1, repeating while held) and Cmd-0 (0, to reset).
    var onZoom: (Int) -> Void = { _ in }
    /// Shortcuts set in Settings that work only while the panel is in front, such as cycling
    /// through notes. They come before the editor, so one can be any key, and repeat while held.
    var shortcuts: [(Shortcut, () -> Void)] = []

    override var canBecomeKey: Bool { true }

    // While the app is inactive the main menu never sees key equivalents, so the panel routes them:
    // its own commands first, then cut, copy and paste to the first responder. Everything else,
    // including Cmd-Z and its key repeats, goes on to the editor page.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // Shift is allowed, since on some keyboards "+" needs it.
        if modifiers.subtracting(.shift) == .command, let key = event.charactersIgnoringModifiers,
            let step = Self.zoomSteps[key]
        {
            onZoom(step)
            return true
        }
        if modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            if let command = commands[key] {
                if !event.isARepeat { command() }
                return true
            }
            if let action = Self.editActions[key] {
                return NSApp.sendAction(action, to: nil, from: self)
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let action = shortcuts.first(where: { $0.0.matches(event) })?.1 {
            action()
            return
        }
        super.sendEvent(event)
    }

    // A double-click on the title bar would otherwise zoom the panel to fill the screen.
    override func zoom(_ sender: Any?) {}

    private static let zoomSteps: [String: Int] = ["+": 1, "=": 1, "-": -1, "0": 0]

    private static let editActions: [String: Selector] = [
        "x": #selector(NSText.cut(_:)),
        "c": #selector(NSText.copy(_:)),
        "v": #selector(NSText.paste(_:)),
    ]
}
