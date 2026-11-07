import Foundation

/// Fits the window to `height`, keeping its top edge until the bottom would leave the screen.
public func fittedFrame(
    _ frame: CGRect, height: CGFloat, minHeight: CGFloat, maxHeight: CGFloat, in visible: CGRect
) -> CGRect {
    let height = min(maxHeight, visible.height, max(minHeight, height.rounded(.up)))
    let top = min(frame.maxY, visible.maxY)
    return CGRect(x: frame.minX, y: max(visible.minY, top - height), width: frame.width, height: height)
}

/// `Untitled` and `Untitled 2` are names nobody chose, so the first line stands in for them.
public func isUntitled(_ name: String) -> Bool {
    name.range(of: #"^Untitled( [0-9]+)?$"#, options: .regularExpression) != nil
}

public func displayTitle(name: String, text: String) -> String {
    guard isUntitled(name) else { return name }
    for line in text.split(whereSeparator: \.isNewline) {
        let title = stripMarkdown(String(line))
        if !title.isEmpty { return String(title.prefix(80)) }
    }
    return name
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

public func conflictName(_ name: String, date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HHmm"
    return "\(name) (conflict \(formatter.string(from: date)))"
}
