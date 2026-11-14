import AppKit
import Carbon.HIToolbox
import NotepanelCore
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

    func hasKeys(of other: Shortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

extension Notification.Name {
    /// Posted with `true` while a shortcut field records keys, and `false` when it stops.
    static let recordingShortcut = Notification.Name("recordingShortcut")
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

// The window's own state lives in @Observable models, not @State: in the macOS 27 SDK @State is
// a macro whose plugin ships only with Xcode, and notepanel builds with the Command Line Tools.

@MainActor
final class SettingsWindow {
    let model = SettingsModel()
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
            centerTitle(of: window)
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

/// From macOS 26, a window's title sits at the leading edge of the title bar. This hides it and
/// shows the same title centered over the window, as before. Where the title bar isn't laid out
/// as expected, the system's title stays.
@MainActor
func centerTitle(of window: NSWindow) {
    guard let close = window.standardWindowButton(.closeButton), let bar = close.superview,
        let content = window.contentView
    else { return }
    window.titleVisibility = .hidden
    let title = NSHostingView(rootView: WindowTitle(text: window.title))
    title.translatesAutoresizingMaskIntoConstraints = false
    bar.addSubview(title)
    NSLayoutConstraint.activate([
        title.centerXAnchor.constraint(equalTo: content.centerXAnchor),
        title.centerYAnchor.constraint(equalTo: close.centerYAnchor),
    ])
}

/// A window title in the title bar's font, dimmed while its window isn't key, as the system's is.
private struct WindowTitle: View {
    let text: String
    @Environment(\.controlActiveState) private var state

    var body: some View {
        Text(text)
            .font(Font(NSFont.titleBarFont(ofSize: 0) as CTFont))
            .foregroundStyle(state == .key ? HierarchicalShapeStyle.primary : .tertiary)
    }
}

@MainActor
@Observable
final class SettingsModel {
    var tab = SettingsTab.general
    private(set) var openAtLogin = false
    private(set) var loginError: String?
    let toggleShortcut = ShortcutRecorder(name: "hotkey.toggle", title: "Show or hide notes")
    let createShortcut = ShortcutRecorder(name: "hotkey.create", title: "New note")
    let searchShortcut = ShortcutRecorder(name: "hotkey.search", title: "Search notes")
    let nextShortcut = ShortcutRecorder(name: "shortcut.nextNote", title: "Next note", global: false)
    let previousShortcut = ShortcutRecorder(name: "shortcut.previousNote", title: "Previous note", global: false)
    let defaultFrameShortcut = ShortcutRecorder(name: "shortcut.defaultFrame", title: "Default place", global: false)
    /// Whether the panel's own commands use a key. The app sets it, as it has the panel.
    var panelTakes: (NSEvent) -> Bool = { _ in false }
    /// The display the panel is on and its default for ⌃⌘M, and setting that default. The app sets
    /// these, as it has the panel.
    var describePlace: () -> DefaultPlace? = { nil }
    var useCurrentFrame: () -> Void = {}
    var useStandardFrame: () -> Void = {}
    private(set) var place: DefaultPlace?
    /// How long the history keeps versions, and saving it. It's in the data folder rather than
    /// UserDefaults, so the app sets these, as it has the note store.
    var readKeepHistory: () -> KeepHistory = { .forever }
    var writeKeepHistory: (KeepHistory) throws -> Void = { _ in }
    private(set) var keepHistory = KeepHistory.forever
    private(set) var historyError: String?
    /// The fixed-pitch font families on this Mac, for the note font menu.
    private(set) var monospacedFonts: [String] = []

    init() {
        for recorder in recorders {
            recorder.usedBy = { [weak self, unowned recorder] event, keys in
                self?.use(of: event, keys, besides: recorder)
            }
        }
    }

    private var recorders: [ShortcutRecorder] {
        [toggleShortcut, createShortcut, searchShortcut, nextShortcut, previousShortcut, defaultFrameShortcut]
    }

    /// What already uses these keys, besides `recorder`: "in the panel", or "for" another shortcut.
    private func use(of event: NSEvent, _ keys: Shortcut, besides recorder: ShortcutRecorder) -> String? {
        if panelTakes(event) { return "in the panel" }
        return recorders.first { $0 !== recorder && $0.shortcut?.hasKeys(of: keys) == true }.map { "for \($0.title)" }
    }

    func refreshPlace() {
        place = describePlace()
    }

    /// Another Mac using the same data folder can change it, so it's read when the window shows.
    func refreshKeepHistory() {
        keepHistory = readKeepHistory()
    }

    /// A limit deletes older versions of every note, which can't be undone, so it asks first.
    /// Setting the same value again afterwards also puts the menu back if the answer was no.
    func chooseKeepHistory(_ keep: KeepHistory) {
        defer { refreshKeepHistory() }
        guard keep != keepHistory else { return }
        if keep.limit != nil {
            let alert = NSAlert()
            alert.messageText = "Delete versions older than 1 year?"
            alert.informativeText = "This deletes them for every note in this data folder. You can’t undo this."
            // Cancel comes first, so Return doesn't delete.
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Delete").hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        do {
            try writeKeepHistory(keep)
            historyError = nil
        } catch {
            historyError = "Couldn’t save: \(error.localizedDescription)"
        }
    }

    /// The login item can be changed in System Settings too, and fonts can be installed, so both
    /// are read each time the window shows.
    func refresh() {
        refreshPlace()
        refreshKeepHistory()
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
    /// What the shortcut does, as Settings shows it.
    let title: String
    /// Works from any app, rather than only in the panel. `allowsShortcut` says which modifiers each
    /// may use.
    let global: Bool
    /// What else uses the keys pressed, if anything. The settings model sets it.
    @ObservationIgnored var usedBy: (NSEvent, Shortcut) -> String? = { _, _ in nil }
    private(set) var shortcut: Shortcut?
    private(set) var recording = false
    /// Why the keys just pressed weren't taken, while recording goes on.
    private(set) var problem: String?
    @ObservationIgnored private var monitor: Any?

    init(name: String, title: String, global: Bool = true) {
        self.name = name
        self.title = title
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
        problem = nil
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
        shortcut = new
        Prefs.setShortcut(new, for: name)
    }
}

enum SettingsTab {
    case general, shortcuts
}

/// A display, as the Default place section shows it, and where ⌃⌘M puts the panel there.
struct DefaultPlace {
    var display: String
    var builtIn: Bool
    var displaySize: NSSize
    var menuBar: CGFloat
    /// From the display's top-left corner, y down.
    var frame: NSRect
    /// Set with Use Current, rather than the standard place and size.
    var custom: Bool
}

struct SettingsView: View {
    let model: SettingsModel
    @AppStorage("dataFolder") private var dataFolder = Prefs.defaultDataFolder
    @AppStorage("fontFamily") private var fontFamily = ""
    @AppStorage("uiFontSize") private var uiFontSize = Prefs.defaultUIFontSize
    @AppStorage("backgroundOpacity") private var backgroundOpacity = Prefs.defaultBackgroundOpacity
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
            ShortcutField(recorder: model.toggleShortcut)
            ShortcutField(recorder: model.createShortcut)
            ShortcutField(recorder: model.searchShortcut)
        }
        Section("Shortcuts in the panel") {
            ShortcutField(recorder: model.nextShortcut)
            ShortcutField(recorder: model.previousShortcut)
            ShortcutField(recorder: model.defaultFrameShortcut)
        }
        HStack {
            Spacer()
            Button("All Keyboard Shortcuts") { KeysWindow.show() }
        }
    }

    @ViewBuilder private var general: some View {
        Section {
            Text(dataFolder)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Picker(
                "Keep history",
                selection: Binding(get: { model.keepHistory }, set: { model.chooseKeepHistory($0) })
            ) {
                Text("Forever").tag(KeepHistory.forever)
                Text("For 1 year").tag(KeepHistory.oneYear)
            }
            if let historyError = model.historyError {
                Text(historyError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("Data folder")
                Spacer()
                Button("Use Default") { dataFolder = Prefs.defaultDataFolder }
                    .disabled(dataFolder == Prefs.defaultDataFolder)
                Button("Choose…", action: chooseFolder)
            }
        }
        // Each display has its own; this shows the panel's. It's set by placing the panel and
        // clicking Use Current, rather than by typing numbers.
        Section {
            if let place = model.place {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: place.display)
                            .lineLimit(2)
                        Text(verbatim: placeSummary(place))
                            .font(.system(size: uiFontSize - 2))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    DisplayMap(place: place, unit: uiFontSize / 15)
                }
            }
        } header: {
            HStack {
                Text("Default place")
                if let keys = model.defaultFrameShortcut.shortcut?.display {
                    keysText(keys)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset", action: model.useStandardFrame)
                    .disabled(model.place?.custom != true)
                    .help("Use the standard place on this display")
                Button("Use Current", action: model.useCurrentFrame)
                    .help("Use the panel’s place and size now, on this display")
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
            // A slider suits this one: it doesn't resize the window, and the panel changes as it moves.
            // Steps of 5% let the knob land exactly on the default, in the middle. macOS 26 draws a
            // tick for every step, all alike, so a short mark under the middle one picks it out. The
            // label sits outside the slider so that the mark centers on the slider alone.
            LabeledContent("Background opacity") {
                Slider(value: $backgroundOpacity, in: 0...1, step: 0.05) {
                    Text("Background opacity")
                }
                .labelsHidden()
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(.secondary)
                        .frame(width: 2, height: 4)
                        .alignmentGuide(.bottom) { $0[.top] - 1 }
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

    /// "Custom · 620 × 410 at (100, 60)", or "Standard · 480 × 360, centered", with the window's size.
    private func placeSummary(_ place: DefaultPlace) -> String {
        let frame = place.frame
        let size = "\(Int(frame.width)) × \(Int(frame.height))"
        return place.custom
            ? "Custom · \(size) at (\(Int(frame.minX)), \(Int(frame.minY)))" : "Standard · \(size), centered"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dataFolder = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// The panel's display in miniature, with the panel where ⌃⌘M puts it. `unit` is 1 at the
/// standard interface text size, 15 pt.
private struct DisplayMap: View {
    let place: DefaultPlace
    let unit: CGFloat

    var body: some View {
        // The screen fits in 64 × 36, a 16:9 display's shape, so a 16:10 one is narrower.
        let scale = unit * min(64 / place.displaySize.width, 36 / place.displaySize.height)
        let screen = CGSize(width: place.displaySize.width * scale, height: place.displaySize.height * scale)
        let panel = place.frame
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: place.menuBar * scale)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: max(3, panel.width * scale), height: max(3, panel.height * scale))
                    .offset(x: panel.minX * scale, y: panel.minY * scale)
            }
            .frame(width: screen.width, height: screen.height, alignment: .topLeading)
            // Darker than the form's box in dark mode and in light mode.
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.tertiary))
            if place.builtIn {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.tertiary)
                    .frame(width: screen.width + 8 * unit, height: 2.5 * unit)
            } else {
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 4 * unit, height: 3 * unit)
                RoundedRectangle(cornerRadius: 1)
                    .fill(.tertiary)
                    .frame(width: 18 * unit, height: 2 * unit)
            }
        }
        .frame(width: 72 * unit)
        .animation(.easeOut(duration: 0.25), value: place.frame)
        // The text beside it says the same.
        .accessibilityHidden(true)
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
