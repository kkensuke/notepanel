import CoreGraphics
import Foundation

/// `Untitled`, `Untitled 2` and so on: the names new notes get.
public func isUntitled(_ name: String) -> Bool {
    isNumbered(name, base: "Untitled")
}

/// `base` itself, or `base 2`, `base 3` and so on.
public func isNumbered(_ name: String, base: String) -> Bool {
    guard name.hasPrefix(base) else { return false }
    let rest = name.dropFirst(base.count)
    return rest.isEmpty || rest.range(of: #"^ [0-9]+$"#, options: .regularExpression) != nil
}

/// The name a note's text suggests: its first non-empty line, without Markdown markers or
/// characters a file name can't hold. Nil if no line gives a usable name.
public func titleFromText(_ text: String) -> String? {
    for line in text.split(whereSeparator: \.isNewline) {
        var title = stripMarkdown(String(line))
            .replacingOccurrences(of: #"[/:]"#, with: "-", options: .regularExpression)
        while title.hasPrefix(".") { title.removeFirst() }
        title = fitted(String(title.prefix(80)).trimmingCharacters(in: .whitespaces))
        if let name = validNoteName(title) { return name }
    }
    return nil
}

/// A note's file name follows its first line until the user gives it another name. It still
/// follows while it's `Untitled` or the title of the text last saved, numbered or not.
public func followsFirstLine(name: String, savedText: String) -> Bool {
    if isUntitled(name) { return true }
    guard let title = titleFromText(savedText) else { return false }
    return isNumbered(name, base: title)
}

func stripMarkdown(_ line: String) -> String {
    var line = line.trimmingCharacters(in: .whitespaces)
    let marker = #"^(#{1,6}\s+|>\s*|[-*+]\s+(\[[ xX]\]\s+)?|[0-9]+[.)]\s+)"#
    if let range = line.range(of: marker, options: .regularExpression) { line.removeSubrange(range) }
    line = line.replacingOccurrences(of: #"[*`~]+"#, with: "", options: .regularExpression)
    return line.trimmingCharacters(in: .whitespaces)
}

/// `base`, then `base 2`, `base 3` and so on, until one is free.
public func makeUniqueName(_ base: String, exists: (String) -> Bool) -> String {
    guard exists(base) else { return base }
    var number = 2
    while exists("\(base) \(number)") { number += 1 }
    return "\(base) \(number)"
}

/// A note's name takes at most this many bytes of UTF-8. A file name holds 255, and the rest is
/// for ".md" and the number a taken name gets.
public let nameLimit = 240

/// `name + suffix`, with `name` cut short if that's too long for a note's name.
func fitted(_ name: String, suffix: String = "") -> String {
    var name = name
    while !name.isEmpty, (name + suffix).utf8.count > nameLimit { name.removeLast() }
    return name + suffix
}

/// The trimmed name, or nil if it can't be a note's file name.
public func validNoteName(_ proposed: String) -> String? {
    let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":"),
        name.utf8.count <= nameLimit
    else { return nil }
    return name
}

/// Where ⌃⌘M puts the panel on a display, given the display's frame and its visible area (without
/// the menu bar and the Dock). A frame saved for the display, relative to its bottom-left corner,
/// is moved inside it if the display has become smaller; one bigger than the display, or none,
/// gives `size`, centered.
public func placeOnDisplay(saved: CGRect?, size: CGSize, display: CGRect, visible: CGRect) -> CGRect {
    if let saved, saved.width <= display.width, saved.height <= display.height {
        let x = min(max(display.minX + saved.minX, display.minX), display.maxX - saved.width)
        let y = min(max(display.minY + saved.minY, display.minY), display.maxY - saved.height)
        return CGRect(x: x, y: y, width: saved.width, height: saved.height)
    }
    return CGRect(
        x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
        width: size.width, height: size.height)
}

/// Whether the panel is still where ⌃⌘M put it. Within a point: the frame AppKit saves for the
/// panel, which it gets back when the app starts, may be rounded.
public func isSameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1
        && abs(a.height - b.height) < 1
}

/// The modifier keys of a shortcut.
public struct ShortcutModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = ShortcutModifiers(rawValue: 1)
    public static let control = ShortcutModifiers(rawValue: 2)
    public static let option = ShortcutModifiers(rawValue: 4)
    public static let shift = ShortcutModifiers(rawValue: 8)
}

/// Whether Settings takes a shortcut with these modifiers. One that works only in the panel needs
/// Command or Control: Shift or Option alone types characters (⇧A, and ⌥A for å) or edits (⇧Tab
/// outdents, ⌥↑ moves lines). One that works from any app needs Command, Control or Option, but
/// not Command alone, which every app uses for its own commands, such as ⌘C.
public func allowsShortcut(_ modifiers: ShortcutModifiers, global: Bool) -> Bool {
    guard global else { return !modifiers.isDisjoint(with: [.command, .control]) }
    return !modifiers.isDisjoint(with: [.command, .control, .option]) && modifiers != .command
}

public func conflictName(_ name: String, date: Date) -> String {
    datedName(name, "conflict", date)
}

/// The name a gone note's history folder moves to, so that a new note can take the name.
public func oldHistoryName(_ name: String, date: Date) -> String {
    datedName(name, "old", date)
}

/// `name (label 2026-11-07 1530)`. A long name is cut short to make room, so the result is
/// still a note's name and fits in a file name.
private func datedName(_ name: String, _ label: String, _ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HHmm"
    return fitted(name, suffix: " (\(label) \(formatter.string(from: date)))")
}

// MARK: - History

/// Local time with its offset from UTC, so that a Mac in another time zone reads the same moment.
private let versionFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HHmmss Z"
    return formatter
}()

/// A version's file name, without `.md`: when it was kept, such as `2026-11-14 203000 +0900`.
public func versionName(_ date: Date) -> String {
    versionFormatter.string(from: date)
}

/// When a version was kept, from its file name without `.md`, which may end in ` 2` and so on.
/// Nil for a name `versionName` doesn't make.
public func versionDate(_ name: String) -> Date? {
    let stamp = String(name.prefix(23))
    guard isNumbered(name, base: stamp) else { return nil }
    return versionFormatter.date(from: stamp)
}

/// The versions to keep: all from the last hour, then the newest in each hour for a day,
/// in each day for a week, and in each week until `limit` (nil keeps them all).
public func versionsToKeep(_ dates: [Date], now: Date, limit: TimeInterval?) -> Set<Date> {
    let hour: TimeInterval = 60 * 60, day = 24 * hour, week = 7 * day
    var kept = Set<Date>(), buckets = Set<[TimeInterval]>()
    for date in dates.sorted(by: >) {
        let size: TimeInterval
        switch now.timeIntervalSince(date) {
        case ..<hour: kept.insert(date); continue
        case ..<day: size = hour
        case ..<week: size = day
        case ..<(limit ?? .infinity): size = week
        default: continue
        }
        // Fixed lengths from 1970 in UTC, so every Mac keeps the same versions in any time zone.
        let bucket = [size, (date.timeIntervalSince1970 / size).rounded(.down)]
        if buckets.insert(bucket).inserted { kept.insert(date) }
    }
    return kept
}

/// How long a note's history keeps the versions a week apart. It lives in the data folder's
/// settings.json, as `{"keepHistory": "1 year"}`, so every Mac using the folder keeps the same.
public enum KeepHistory: String, Sendable {
    case forever
    case oneYear = "1 year"

    /// Anything that can't be read, or no file at all, keeps versions forever: a damaged file
    /// never deletes them.
    public init(settings: Data?) {
        let object = settings.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        self = (object?["keepHistory"] as? String).flatMap(KeepHistory.init(rawValue:)) ?? .forever
    }

    /// The age past which versions go, or nil to keep them.
    public var limit: TimeInterval? { self == .oneYear ? 365 * 24 * 60 * 60 : nil }
}

// MARK: - Pins

// Pinned notes are kept by name, in the order the user gave them. These work out what that list
// becomes; the app keeps it.

/// A renamed note keeps its place.
public func pinsRenaming(_ pins: [String], _ old: String, to new: String) -> [String] {
    var pins = pins
    if let index = pins.firstIndex(of: old) { pins[index] = new }
    return pins
}

/// A note pinned goes at the end; pinned again, it's taken away.
public func pinsToggling(_ pins: [String], _ name: String) -> [String] {
    var pins = pins
    if let index = pins.firstIndex(of: name) { pins.remove(at: index) } else { pins.append(name) }
    return pins
}

/// The switcher sends the pinned notes it shows, in their new order. Pins whose file is missing
/// aren't shown, so they keep their place after the others. Nil unless `shown` is some of the
/// pins, each once.
public func pinsReordered(_ pins: [String], shown: [String]) -> [String]? {
    guard Set(shown).count == shown.count, Set(shown).isSubset(of: pins) else { return nil }
    return shown + pins.filter { !shown.contains($0) }
}

/// Pinned notes first, in the order the user gave them, then the rest in the order they came.
public func pinnedFirst(_ names: [String], pins: [String]) -> [String] {
    pins.filter(names.contains) + names.filter { !pins.contains($0) }
}
