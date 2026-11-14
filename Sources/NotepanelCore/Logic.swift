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
        title = String(title.prefix(80)).trimmingCharacters(in: .whitespaces)
        while title.utf8.count > 240 { title.removeLast() }
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

/// The trimmed name, or nil if it can't be a note's file name.
public func validNoteName(_ proposed: String) -> String? {
    let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":"),
        name.utf8.count <= 240
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

private func datedName(_ name: String, _ label: String, _ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HHmm"
    return "\(name) (\(label) \(formatter.string(from: date)))"
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
