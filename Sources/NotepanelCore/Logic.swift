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

public func conflictName(_ name: String, date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HHmm"
    return "\(name) (conflict \(formatter.string(from: date)))"
}
