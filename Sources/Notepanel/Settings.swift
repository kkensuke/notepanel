import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

struct Shortcut: Codable, Equatable {
    var keyCode: Int
    /// Carbon modifier flags, as `RegisterEventHotKey` takes them.
    var modifiers: Int
    var display: String

    func matches(_ event: NSEvent) -> Bool {
        Int(event.keyCode) == keyCode && carbonModifiers(event.modifierFlags) == modifiers
    }
}

extension Notification.Name {
    /// Posted with `true` while a shortcut field records keys, and `false` when it stops.
    static let recordingShortcut = Notification.Name("recordingShortcut")
}

/// Settings live in UserDefaults. The settings window edits the same keys through @AppStorage.
enum Prefs {
    static let defaultFolder = "~/Library/Application Support/notepanel/Notes"
    static let defaultFontSize = 14.0
    static let fontSizes = 9.0...36.0
    /// The text size of everything but the note: the title bar, the switcher, the footer and the
    /// settings window. The toolbar's symbols follow it.
    static let defaultUIFontSize = 15.0
    static let uiFontSizes: [Double] = [12, 13, 14, 15, 16, 17, 18, 20]
    /// The note panel's opacity, text included. It stops at 20%, so the panel can't get lost.
    static let defaultPanelOpacity = 1.0
    static let panelOpacities = 0.2...1.0
    /// Global shortcuts, which work from any app.
    static let hotKeyNames = ["hotkey.toggle", "hotkey.create", "hotkey.search"]
    static let defaultShortcuts: [String: Shortcut] = [
        "hotkey.toggle": Shortcut(keyCode: kVK_ANSI_N, modifiers: controlKey | cmdKey, display: "⌃⌘N"),
        "shortcut.nextNote": Shortcut(keyCode: kVK_Tab, modifiers: controlKey, display: "⌃⇥"),
        "shortcut.previousNote": Shortcut(keyCode: kVK_Tab, modifiers: controlKey | shiftKey, display: "⌃⇧⇥"),
    ]

    static var folder: URL {
        let path = UserDefaults.standard.string(forKey: "folder") ?? defaultFolder
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Outside the notes folder, so backups never show up as notes.
    static let backups = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("notepanel/Backups", isDirectory: true)

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
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            // Above the note panel, which floats.
            window.level = .floating
            window.center()
            self.window = window
        }
        model.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// For ⌘,: a second press closes the window.
    func toggle() {
        if window?.isVisible == true { window?.close() } else { show() }
    }
}

@MainActor
@Observable
final class SettingsModel {
    var tab = SettingsTab.general
    private(set) var openAtLogin = false
    private(set) var loginError: String?
    let toggleShortcut = ShortcutRecorder(name: "hotkey.toggle")
    let createShortcut = ShortcutRecorder(name: "hotkey.create")
    let searchShortcut = ShortcutRecorder(name: "hotkey.search")
    let nextShortcut = ShortcutRecorder(name: "shortcut.nextNote", global: false)
    let previousShortcut = ShortcutRecorder(name: "shortcut.previousNote", global: false)
    /// The fixed-pitch font families on this Mac, for the note font menu.
    private(set) var monospacedFonts: [String] = []

    /// The login item can be changed in System Settings too, and fonts can be installed, so both
    /// are read each time the window shows.
    func refresh() {
        openAtLogin = SMAppService.mainApp.status == .enabled
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        // Families starting with "." are the system's own, hidden from users.
        let families = Set(names.compactMap { NSFont(name: $0, size: 0)?.familyName }).filter { !$0.hasPrefix(".") }
        monospacedFonts = families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
    /// A global shortcut needs Command, Control or Option, so typing can't trigger it. One that
    /// works only in the panel may use Shift alone.
    let global: Bool
    private(set) var shortcut: Shortcut?
    private(set) var recording = false
    @ObservationIgnored private var monitor: Any?

    init(name: String, global: Bool = true) {
        self.name = name
        self.global = global
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
        guard !flags.isDisjoint(with: global ? [.control, .option, .command] : [.control, .option, .command, .shift])
        else {
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

enum SettingsTab {
    case general, shortcuts
}

struct SettingsView: View {
    let model: SettingsModel
    @AppStorage("folder") private var folder = Prefs.defaultFolder
    @AppStorage("fontFamily") private var fontFamily = ""
    @AppStorage("uiFontSize") private var uiFontSize = Prefs.defaultUIFontSize
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("showWhitespace") private var showWhitespace = false
    @AppStorage("indentSize") private var indentSize = 4

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: Binding(get: { model.tab }, set: { model.tab = $0 })) {
                Text("General").tag(SettingsTab.general)
                Text("Shortcuts").tag(SettingsTab.shortcuts)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            // A click anywhere on it switches to the other tab, as on a toggle.
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.tab = model.tab == .general ? .shortcuts : .general }
            }
            .padding(.top, 12)
            ZStack(alignment: .top) {
                page(.general) { general }
                page(.shortcuts) { shortcuts }
            }
        }
        .font(.system(size: uiFontSize))
        .controlSize(uiFontSize >= 17 ? .large : .regular)
        .frame(width: uiFontSize * 26)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Both tabs are laid out and the other one is hidden, so the window is as tall as the taller
    /// tab and keeps its height when the tab changes.
    private func page<Content: View>(_ tab: SettingsTab, @ViewBuilder _ content: () -> Content) -> some View {
        let shown = model.tab == tab
        return Form(content: content)
            .formStyle(.grouped)
            .scrollDisabled(true)
            .opacity(shown ? 1 : 0)
            .disabled(!shown)
            .accessibilityHidden(!shown)
    }

    @ViewBuilder private var shortcuts: some View {
        Section("Shortcuts from any app") {
            ShortcutField(title: "Show or hide notes", recorder: model.toggleShortcut)
            ShortcutField(title: "New note", recorder: model.createShortcut)
            ShortcutField(title: "Search notes", recorder: model.searchShortcut)
        }
        Section("Shortcuts in the panel") {
            ShortcutField(title: "Next note", recorder: model.nextShortcut)
            ShortcutField(title: "Previous note", recorder: model.previousShortcut)
        }
        HStack {
            Spacer()
            Button("All Keyboard Shortcuts") { KeysWindow.show() }
        }
    }

    @ViewBuilder private var general: some View {
        Section {
            Text(folder)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } header: {
            HStack {
                Text("Notes folder")
                Spacer()
                Button("Use Default") { folder = Prefs.defaultFolder }
                    .disabled(folder == Prefs.defaultFolder)
                Button("Choose…", action: chooseFolder)
            }
        }
        // The notes' text size has no control here: ⌘+, ⌘− and ⌘0 in the panel change it.
        Section("Appearance") {
            Picker("Note font", selection: $fontFamily) {
                Text("Default (SF Mono)").tag("")
                // A font that isn't in the list, such as one typed in before this was a menu, stays.
                if !fontFamily.isEmpty && !model.monospacedFonts.contains(fontFamily) {
                    Text(verbatim: fontFamily).tag(fontFamily)
                }
                ForEach(model.monospacedFonts, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            // A menu rather than a stepper: this setting resizes the window, which would move a
            // stepper's arrows out from under the pointer after every click.
            Picker("Interface text size", selection: $uiFontSize) {
                ForEach(Prefs.uiFontSizes, id: \.self) { size in
                    Text(verbatim: "\(Int(size)) pt").tag(size)
                }
            }
            Toggle("Show whitespace", isOn: $showWhitespace)
            Picker("Tab key indents by", selection: $indentSize) {
                Text("2 spaces").tag(2)
                Text("4 spaces").tag(4)
            }
        }
        Section {
            Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
            Toggle(
                "Open at login",
                isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            if let loginError = model.loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }
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

func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
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
