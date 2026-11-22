import AppKit
import Carbon.HIToolbox

struct Shortcut: Codable, Equatable {
    var keyCode: Int
    /// Carbon modifier flags, as `RegisterEventHotKey` takes them.
    var modifiers: Int
    var display: String

    func matches(_ event: NSEvent) -> Bool {
        Int(event.keyCode) == keyCode && carbonModifiers(event.modifierFlags) == modifiers
    }

    func hasKeys(of other: Shortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

/// What ⌃⌘M changed, so that pressing it again takes it back: the panel's frame and the note's text
/// size before, nil if it was never set, and the frame it put the panel at.
struct BeforeDefault: Codable {
    var frame: NSRect
    var fontSize: Double?
    var placed: NSRect
}

/// Settings live in UserDefaults. The settings window edits the same keys through @AppStorage.
enum Prefs {
    /// The names settings are kept under. They must never change: under a new name, what the
    /// user set is gone.
    enum Key {
        static let dataFolder = "dataFolder"
        static let fontFamily = "fontFamily"
        static let fontSize = "fontSize"
        static let uiFontSize = "uiFontSize"
        static let backgroundOpacity = "backgroundOpacity"
        static let showWhitespace = "showWhitespace"
        static let indentSize = "indentSize"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let defaultFrames = "defaultFrames"
        static let defaultFontSizes = "defaultFontSizes"
        static let beforeDefault = "beforeDefault"
        static let pinned = "pinned"
        static let lastNote = "lastNote"
        static let sideWidth = "sideWidth"
        static let hotkeyToggle = "hotkey.toggle"
        static let hotkeyCreate = "hotkey.create"
        static let hotkeySearch = "hotkey.search"
        static let shortcutNextNote = "shortcut.nextNote"
        static let shortcutPreviousNote = "shortcut.previousNote"
        static let shortcutDefaultFrame = "shortcut.defaultFrame"
    }

    static let defaultDataFolder = "~/Library/Application Support/notepanel"
    static let defaultFontSize = 14.0
    static let fontSizes = 9.0...36.0
    /// The text size of everything but the note: the title bar, the switcher, the footer and the
    /// settings window. The toolbar's symbols follow it.
    static let defaultUIFontSize = 15.0
    static let uiFontSizes: [Double] = [12, 13, 14, 15, 16, 17, 18, 20]
    /// How wide the switcher is, in its window at the panel's left, in points. Dragging the
    /// switcher's left edge changes it.
    static let defaultSideWidth = 220.0
    static let minSideWidth = 140.0
    /// The note panel's background, not its text: 0 is clear, 1 is solid, and the default in
    /// between is tinycast's glass and scrim.
    static let defaultBackgroundOpacity = 0.5
    /// The spaces the Tab key adds, 2 or 4.
    static let defaultIndentSize = 4
    static let defaultShowMenuBarIcon = true
    /// Global shortcuts, which work from any app.
    static let hotKeyNames = [Key.hotkeyToggle, Key.hotkeyCreate, Key.hotkeySearch]
    static let defaultShortcuts: [String: Shortcut] = [
        Key.hotkeyToggle: Shortcut(keyCode: kVK_ANSI_N, modifiers: controlKey | cmdKey, display: "⌃⌘N"),
        Key.shortcutNextNote: Shortcut(keyCode: kVK_Tab, modifiers: controlKey, display: "⌃⇥"),
        Key.shortcutPreviousNote: Shortcut(keyCode: kVK_Tab, modifiers: controlKey | shiftKey, display: "⌃⇧⇥"),
        Key.shortcutDefaultFrame: Shortcut(keyCode: kVK_ANSI_M, modifiers: controlKey | cmdKey, display: "⌃⌘M"),
    ]

    /// Holds the notes, their history and settings.json, which `NoteStore` keeps there.
    static var dataFolder: URL {
        let path = UserDefaults.standard.string(forKey: Key.dataFolder) ?? defaultDataFolder
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The frame ⌃⌘M gives the panel on a display, set in Settings, by `NSScreen.displayKey`; nil for
    /// the standard one. It's relative to the display's bottom-left corner, so it moves with the
    /// display when displays are rearranged.
    static func defaultFrame(for display: String) -> NSRect? {
        (UserDefaults.standard.dictionary(forKey: Key.defaultFrames)?[display] as? String).map(NSRectFromString)
    }

    /// The note's text size ⌃⌘M sets on a display, saved with its frame. A frame saved before the
    /// text size was saved with it, or none, has the default text size.
    static func defaultFontSize(for display: String) -> Double {
        UserDefaults.standard.dictionary(forKey: Key.defaultFontSizes)?[display] as? Double ?? defaultFontSize
    }

    /// Sets the frame and the text size together, so that Reset clears both.
    static func setDefaultFrame(_ frame: NSRect?, fontSize: Double?, for display: String) {
        let defaults = UserDefaults.standard
        var sizes = defaults.dictionary(forKey: Key.defaultFontSizes) ?? [:]
        sizes[display] = fontSize
        defaults.set(sizes, forKey: Key.defaultFontSizes)
        var frames = defaults.dictionary(forKey: Key.defaultFrames) ?? [:]
        frames[display] = frame.map(NSStringFromRect)
        defaults.set(frames, forKey: Key.defaultFrames)
    }

    /// What ⌃⌘M last changed, until a second press takes it back. Kept here, not in memory, so that
    /// the second press works after the app quits too.
    static var beforeDefault: BeforeDefault? {
        get {
            UserDefaults.standard.data(forKey: Key.beforeDefault)
                .flatMap { try? JSONDecoder().decode(BeforeDefault.self, from: $0) }
        }
        set {
            let data = newValue.flatMap { try? JSONEncoder().encode($0) }
            UserDefaults.standard.set(data, forKey: Key.beforeDefault)
        }
    }

    /// A shortcut that was never set has its default; one stored as an empty string is off.
    static func shortcut(_ name: String) -> Shortcut? {
        guard let stored = UserDefaults.standard.string(forKey: name) else { return defaultShortcuts[name] }
        return try? JSONDecoder().decode(Shortcut.self, from: Data(stored.utf8))
    }

    static func setShortcut(_ shortcut: Shortcut?, for name: String) {
        let json = shortcut.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        UserDefaults.standard.set(json ?? "", forKey: name)
    }

    /// Pinned notes by name, kept per notes folder. Not in the folder, so the notes stay plain files.
    static func pinned(in folder: URL) -> [String] {
        (UserDefaults.standard.dictionary(forKey: Key.pinned)?[folder.path] as? [String]) ?? []
    }

    static func setPinned(_ names: [String], in folder: URL) {
        var all = UserDefaults.standard.dictionary(forKey: Key.pinned) ?? [:]
        all[folder.path] = names.isEmpty ? nil : names
        UserDefaults.standard.set(all, forKey: Key.pinned)
    }
}

func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
    var result = 0
    if flags.contains(.command) { result |= cmdKey }
    if flags.contains(.option) { result |= optionKey }
    if flags.contains(.control) { result |= controlKey }
    if flags.contains(.shift) { result |= shiftKey }
    return result
}
