import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

struct Shortcut: Codable, Equatable {
    var keyCode: Int
    /// Carbon modifier flags, as `RegisterEventHotKey` takes them.
    var modifiers: Int
    var display: String
}

extension Notification.Name {
    /// Posted with `true` while a shortcut field records keys, and `false` when it stops.
    static let recordingShortcut = Notification.Name("recordingShortcut")
}

/// Settings live in UserDefaults. The settings window edits the same keys through @AppStorage.
enum Prefs {
    static let defaultFolder = "~/Library/Application Support/notepanel/Notes"
    static let hotKeyNames = ["hotkey.toggle", "hotkey.create", "hotkey.search"]
    static let defaultToggle = Shortcut(keyCode: kVK_ANSI_N, modifiers: controlKey | cmdKey, display: "⌃⌘N")

    static var folder: URL {
        let path = UserDefaults.standard.string(forKey: "folder") ?? defaultFolder
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// A shortcut that was never set has its default; one stored as an empty string is off.
    static func shortcut(_ name: String) -> Shortcut? {
        guard let stored = UserDefaults.standard.string(forKey: name) else {
            return name == "hotkey.toggle" ? defaultToggle : nil
        }
        return try? JSONDecoder().decode(Shortcut.self, from: Data(stored.utf8))
    }

    static func setShortcut(_ shortcut: Shortcut?, for name: String) {
        let json = shortcut.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        UserDefaults.standard.set(json ?? "", forKey: name)
    }
}

// The window's own state lives in @Observable models, not @State: in the macOS 27 SDK @State is
// a macro whose plugin ships only with Xcode, and notepanel builds with the Command Line Tools.

@MainActor
final class SettingsWindow {
    private let model = SettingsModel()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "notepanel Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // Above the note panel, which floats.
            window.level = .floating
            window.center()
            self.window = window
        }
        model.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
@Observable
final class SettingsModel {
    private(set) var openAtLogin = false
    private(set) var loginError: String?
    let toggleShortcut = ShortcutRecorder(name: "hotkey.toggle")
    let createShortcut = ShortcutRecorder(name: "hotkey.create")
    let searchShortcut = ShortcutRecorder(name: "hotkey.search")

    /// The login item can be changed in System Settings too, so it's read each time the window shows.
    func refresh() {
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        refresh()
    }
}

/// Click, then press the shortcut. Esc cancels, and the x button removes the shortcut.
@MainActor
@Observable
final class ShortcutRecorder {
    let name: String
    private(set) var shortcut: Shortcut?
    private(set) var recording = false
    @ObservationIgnored private var monitor: Any?

    init(name: String) {
        self.name = name
        shortcut = Prefs.shortcut(name)
    }

    func toggle() {
        if recording { stop() } else { start() }
    }

    func clear() {
        save(nil)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        NotificationCenter.default.post(name: .recordingShortcut, object: false)
    }

    private func start() {
        recording = true
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
        guard !flags.isDisjoint(with: [.control, .option, .command]) else {
            NSSound.beep()
            return
        }
        save(Shortcut(keyCode: keyCode, modifiers: carbonModifiers(flags), display: symbols(flags) + keyName(event)))
        stop()
    }

    private func save(_ new: Shortcut?) {
        shortcut = new
        Prefs.setShortcut(new, for: name)
    }
}

struct SettingsView: View {
    let model: SettingsModel
    @AppStorage("folder") private var folder = Prefs.defaultFolder
    @AppStorage("fontFamily") private var fontFamily = ""
    @AppStorage("fontSize") private var fontSize = 14.0
    @AppStorage("maxHeight") private var maxHeight = 640.0

    var body: some View {
        Form {
            Section("Shortcuts") {
                ShortcutField(title: "Show or hide notes", recorder: model.toggleShortcut)
                ShortcutField(title: "New note", recorder: model.createShortcut)
                ShortcutField(title: "Search notes", recorder: model.searchShortcut)
            }
            Section("Notes folder") {
                Text(folder)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("Use Default") { folder = Prefs.defaultFolder }
                        .disabled(folder == Prefs.defaultFolder)
                    Button("Choose…", action: chooseFolder)
                }
            }
            Section("Editor") {
                TextField("Font", text: $fontFamily, prompt: Text("SF Mono"))
                Stepper("Font size: \(Int(fontSize)) pt", value: $fontSize, in: 9...36)
                Stepper("Maximum height: \(Int(maxHeight)) pt", value: $maxHeight, in: 200...2400, step: 40)
            }
            Section {
                Toggle(
                    "Open at login",
                    isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                if let loginError = model.loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

struct ShortcutField: View {
    let title: String
    let recorder: ShortcutRecorder

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Button(recorder.recording ? "Type a shortcut…" : (recorder.shortcut?.display ?? "Record Shortcut")) {
                    recorder.toggle()
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
        }
        .onDisappear { recorder.stop() }
    }
}

private let modifierSymbols: [(NSEvent.ModifierFlags, String)] = [
    (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
]

private func symbols(_ flags: NSEvent.ModifierFlags) -> String {
    modifierSymbols.filter { flags.contains($0.0) }.map(\.1).joined()
}

private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
    var result = 0
    if flags.contains(.command) { result |= cmdKey }
    if flags.contains(.option) { result |= optionKey }
    if flags.contains(.control) { result |= controlKey }
    if flags.contains(.shift) { result |= shiftKey }
    return result
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
