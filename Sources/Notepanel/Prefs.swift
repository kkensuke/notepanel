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

/// Settings live in UserDefaults. The settings window edits the same keys through @AppStorage.
enum Prefs {
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
    /// Global shortcuts, which work from any app.
    static let hotKeyNames = ["hotkey.toggle", "hotkey.create", "hotkey.search"]
    static let defaultShortcuts: [String: Shortcut] = [
        "hotkey.toggle": Shortcut(keyCode: kVK_ANSI_N, modifiers: controlKey | cmdKey, display: "⌃⌘N"),
        "shortcut.nextNote": Shortcut(keyCode: kVK_Tab, modifiers: controlKey, display: "⌃⇥"),
        "shortcut.previousNote": Shortcut(keyCode: kVK_Tab, modifiers: controlKey | shiftKey, display: "⌃⇧⇥"),
        "shortcut.defaultFrame": Shortcut(keyCode: kVK_ANSI_M, modifiers: controlKey | cmdKey, display: "⌃⌘M"),
    ]

    /// Holds the notes, their history and settings.json, which `NoteStore` keeps there.
    static var dataFolder: URL {
        let path = UserDefaults.standard.string(forKey: "dataFolder") ?? defaultDataFolder
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The frame ⌃⌘M gives the panel on a display, set in Settings, by `NSScreen.displayKey`; nil for
    /// the standard one. It's relative to the display's bottom-left corner, so it moves with the
    /// display when displays are rearranged.
    static func defaultFrame(for display: String) -> NSRect? {
        (UserDefaults.standard.dictionary(forKey: "defaultFrames")?[display] as? String).map(NSRectFromString)
    }

    static func setDefaultFrame(_ frame: NSRect?, for display: String) {
        var all = UserDefaults.standard.dictionary(forKey: "defaultFrames") ?? [:]
        all[display] = frame.map(NSStringFromRect)
        UserDefaults.standard.set(all, forKey: "defaultFrames")
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
        (UserDefaults.standard.dictionary(forKey: "pinned")?[folder.path] as? [String]) ?? []
    }

    static func setPinned(_ names: [String], in folder: URL) {
        var all = UserDefaults.standard.dictionary(forKey: "pinned") ?? [:]
        all[folder.path] = names.isEmpty ? nil : names
        UserDefaults.standard.set(all, forKey: "pinned")
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
