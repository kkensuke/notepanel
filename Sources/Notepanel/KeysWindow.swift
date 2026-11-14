import AppKit
import SwiftUI

/// A list of notepanel's keys, opened with ⇧⌘/ in the panel, from Settings or from the menu bar
/// icon's menu.
@MainActor
enum KeysWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: KeysView())
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Keyboard Shortcuts"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            // Above the note panel, which floats.
            window.level = .floating
            window.center()
            self.window = window
        }
        // Built again each time, so the shortcuts set in Settings are up to date.
        (window?.contentViewController as? NSHostingController<KeysView>)?.rootView = KeysView()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// For ⇧⌘/: a second press closes the window.
    static func toggle() {
        if window?.isVisible == true { window?.close() } else { show() }
    }
}

// Keep these in step with the Keys sections of README.md and README.ja.md.

private let windowKeys = [
    ("Open or close Settings", "⌘,"),
    ("Open or close this list", "⇧⌘/"),
    ("Quit", "⌘Q"),
]

private let panelKeys = [
    ("New note", "⌘N"),
    ("Switch notes", "⌘P"),
    ("Earlier versions of the note", "⌘Y"),
    ("Open a pinned note", "⌘1 … ⌘9"),
    ("Open the notes folder", "⌘O"),
    ("Bigger / smaller note text", "⌘+ / ⌘−"),
    ("Default note text size", "⌘0"),
    ("Hide", "⌘W or Esc"),
]

private let switcherKeys = [
    ("Choose a note", "↑ / ↓"),
    ("Open it", "↩"),
    ("Move it to the Trash", "⌘⌫"),
    ("Move a pinned note up / down", "⌥↑ / ⌥↓"),
]

private let historyKeys = [
    ("Choose a version", "↑ / ↓"),
    ("Copy all of it", "↩"),
    ("Select all of it", "⌘A"),
    ("Copy what’s selected", "⌘C"),
    ("Close", "Esc or ⌘Y"),
]

private let editingKeys = [
    ("Delete to the line start", "⌘⌫"),
    ("Line start / line end", "⌘← / ⌘→"),
    ("Move lines up / down", "⌥↑ / ⌥↓"),
    ("Copy lines up / down", "⇧⌥↑ / ⇧⌥↓"),
    ("Delete line", "⇧⌘K"),
    ("Select line", "⌘L"),
    ("Insert a line below / above", "⌘↩ / ⇧⌘↩"),
    ("Select the next match", "⌘D"),
    ("Select all matches", "⇧⌘L"),
    ("Add a cursor above / below", "⌥⌘↑ / ⌥⌘↓"),
    ("Add a cursor", "⌥-click"),
    ("Rectangular selection", "⇧⌥-drag"),
    ("Find and replace", "⌘F"),
    ("Next / previous match", "⌘G / ⇧⌘G"),
    ("Bold / italic", "⌘B / ⌘I"),
    ("Strikethrough / code", "⇧⌘X / ⌘E"),
    ("Make a link", "⌘K"),
    ("Open a link", "⌘-click"),
    ("Tick or clear a task", "Click [ ] or [x]"),
]

private struct KeysView: View {
    @AppStorage("uiFontSize") private var uiFontSize = Prefs.defaultUIFontSize

    var body: some View {
        Form {
            Section("From any app") {
                setting("Show or hide notes", "hotkey.toggle")
                setting("New note", "hotkey.create")
                setting("Search notes", "hotkey.search")
            }
            Section("In the panel, Settings and this list") { rows(windowKeys) }
            Section("In the panel") {
                rows(panelKeys)
                setting("Next note", "shortcut.nextNote")
                setting("Previous note", "shortcut.previousNote")
                setting("Default place and size, and back", "shortcut.defaultFrame")
            }
            Section("In the switcher") { rows(switcherKeys) }
            Section("In earlier versions") { rows(historyKeys) }
            Section("Editing") { rows(editingKeys) }
        }
        .formStyle(.grouped)
        .font(.system(size: uiFontSize))
        // The list is longer than most screens are tall, so it scrolls.
        .frame(width: uiFontSize * 28, height: uiFontSize * 36)
    }

    private func rows(_ keys: [(String, String)]) -> some View {
        ForEach(keys.indices, id: \.self) { i in
            LabeledContent(keys[i].0) { keysText(keys[i].1) }
        }
    }

    /// A shortcut that can be changed in Settings, as it's set now.
    private func setting(_ does: String, _ name: String) -> some View {
        LabeledContent(does) { keysText(Prefs.shortcut(name)?.display ?? "Off") }
    }
}

/// Keys as text, with a slashed zero so that ⌘0 doesn't read as ⌘O. The zero takes the font's
/// fixed-width variant: SF Mono slashes its zero, SF Pro doesn't.
func keysText(_ keys: String) -> Text {
    let parts = keys.split(separator: "0", omittingEmptySubsequences: false)
    var text = Text(verbatim: String(parts[0]))
    for part in parts.dropFirst() {
        text = Text("\(text)\(Text(verbatim: "0").monospaced())\(Text(verbatim: String(part)))")
    }
    return text
}
