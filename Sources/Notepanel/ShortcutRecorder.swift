import AppKit
import Carbon.HIToolbox
import NotepanelCore
import SwiftUI

extension Notification.Name {
    /// Posted with `true` while a shortcut field records keys, and `false` when it stops.
    static let recordingShortcut = Notification.Name("recordingShortcut")
}

/// Click, then press the shortcut. Esc cancels, and the x button removes the shortcut.
@MainActor
@Observable
final class ShortcutRecorder {
    let name: String
    /// What the shortcut does, as Settings shows it.
    let title: String
    /// Works from any app, rather than only in the panel. `allowsShortcut` says which modifiers each
    /// may use.
    let global: Bool
    /// What else uses the keys pressed, or the default (with no event), if anything. The settings
    /// model sets it.
    @ObservationIgnored var usedBy: (NSEvent?, Shortcut) -> String? = { _, _ in nil }
    /// Runs as recording starts. The settings model sets it.
    @ObservationIgnored var willRecord: () -> Void = {}
    let defaultShortcut: Shortcut?
    private(set) var shortcut: Shortcut?
    private(set) var recording = false
    /// Why the keys just pressed, or the default, weren't taken. It goes when recording starts or
    /// stops, or the shortcut changes.
    private(set) var problem: String?
    @ObservationIgnored private var monitor: Any?

    init(name: String, title: String, global: Bool = true) {
        self.name = name
        self.title = title
        self.global = global
        defaultShortcut = Prefs.defaultShortcuts[name]
        shortcut = Prefs.shortcut(name)
    }

    /// There's a default, and the field has other keys.
    var canReset: Bool {
        guard let defaultShortcut else { return false }
        return shortcut?.hasKeys(of: defaultShortcut) != true
    }

    func toggle() {
        if recording { stop() } else { start() }
    }

    func clear() {
        save(nil)
    }

    /// Puts the default back without recording it: while a field records, notepanel's hot keys are
    /// off, and another app's hot key with the same keys takes them before the field sees them.
    func reset() {
        guard let defaultShortcut else { return }
        // Not checked against the panel's commands, which use ⌘ alone or ⇧⌘, as no default does.
        if let use = usedBy(nil, defaultShortcut) {
            refuse("\(defaultShortcut.display) is already used \(use)")
            return
        }
        save(defaultShortcut)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        problem = nil
        guard recording else { return }
        recording = false
        NotificationCenter.default.post(name: .recordingShortcut, object: false)
    }

    private func start() {
        willRecord()
        recording = true
        problem = nil
        // Otherwise pressing a registered shortcut would trigger it instead of recording it.
        NotificationCenter.default.post(name: .recordingShortcut, object: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            MainActor.assumeIsolated { self?.record(event) }
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        if keyCode == kVK_Escape {
            stop()
            return
        }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard allowsShortcut(ShortcutModifiers(flags), global: global) else {
            refuse(global ? "Needs ⌃ or ⌥, or ⇧⌘" : "Needs ⌘ or ⌃")
            return
        }
        let new = Shortcut(
            keyCode: keyCode, modifiers: carbonModifiers(flags), display: symbols(flags) + keyName(event))
        if let use = usedBy(event, new) {
            refuse("\(new.display) is already used \(use)")
            return
        }
        save(new)
        stop()
    }

    private func refuse(_ why: String) {
        problem = why
        NSSound.beep()
    }

    private func save(_ new: Shortcut?) {
        problem = nil
        shortcut = new
        Prefs.setShortcut(new, for: name)
    }
}

struct ShortcutField: View {
    let recorder: ShortcutRecorder

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Button(recorder.recording ? "Type a shortcut…" : (recorder.shortcut?.display ?? "Record Shortcut")) {
                    recorder.toggle()
                }
                if let defaultShortcut = recorder.defaultShortcut, recorder.canReset, !recorder.recording {
                    Button {
                        recorder.reset()
                    } label: {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to \(defaultShortcut.display)")
                    .accessibilityLabel("Reset to default shortcut")
                }
                if recorder.shortcut != nil, !recorder.recording {
                    Button {
                        recorder.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove shortcut")
                    .accessibilityLabel("Remove shortcut")
                }
            }
        } label: {
            Text(recorder.title)
            // Under the title, as a form row's second line.
            if let problem = recorder.problem {
                Text(problem)
                    .foregroundStyle(.red)
            }
        }
    }
}

private let modifierSymbols: [(NSEvent.ModifierFlags, String)] = [
    (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
]

private func symbols(_ flags: NSEvent.ModifierFlags) -> String {
    modifierSymbols.filter { flags.contains($0.0) }.map(\.1).joined()
}

extension ShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
    }
}

private let keyNames: [Int: String] = [
    kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
]

private func keyName(_ event: NSEvent) -> String {
    keyNames[Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
}
