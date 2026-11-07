// Assertion-based checks for NotepanelCore. Run with `swift run NotepanelChecks`.
// They stand in for XCTest, which the Command Line Tools don't include.
import Foundation
import NotepanelCore

var failures = 0

func fail(_ message: String, _ line: Int) {
    print("FAIL (line \(line)): \(message)")
    failures += 1
}

func check(_ condition: @autoclosure () throws -> Bool, _ label: String, line: Int = #line) {
    do {
        if try !condition() { fail(label, line) }
    } catch {
        fail("\(label), threw \(error)", line)
    }
}

func equal<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: T, line: Int = #line) {
    do {
        let value = try actual()
        if value != expected { fail("got \(value), expected \(expected)", line) }
    } catch {
        fail("threw \(error), expected \(expected)", line)
    }
}

func throwsError<E: Error & Equatable, R>(_ expected: E, line: Int = #line, _ body: () throws -> R) {
    do {
        _ = try body()
        fail("no error, expected \(expected)", line)
    } catch let error as E where error == expected {
        return
    } catch {
        fail("threw \(error), expected \(expected)", line)
    }
}

/// Runs `body` with a fresh folder that is removed afterwards.
func inFolder(line: Int = #line, _ body: (URL) throws -> Void) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
        try body(folder)
    } catch {
        fail("threw \(error)", line)
    }
}

struct Missing: Error {}

func unwrapped<T>(_ value: T?) throws -> T {
    guard let value else { throw Missing() }
    return value
}

func contents(_ store: NoteStore, _ name: String) throws -> String {
    try String(contentsOf: store.url(name), encoding: .utf8)
}

// MARK: - Names

equal(titleFromText("\n\n# Shopping **list**\n- milk"), "Shopping list")
equal(titleFromText("- [ ] Call Sam"), "Call Sam")
equal(titleFromText("1. First"), "First")
equal(titleFromText("Q3/Q4: plans"), "Q3-Q4- plans")
equal(titleFromText("...dots"), "dots")
equal(titleFromText("  \n"), nil)
equal(titleFromText(String(repeating: "a", count: 100))?.count, 80)

check(isUntitled("Untitled"), "Untitled")
check(isUntitled("Untitled 12"), "Untitled 12")
check(!isUntitled("Untitled ideas"), "Untitled ideas")
check(followsFirstLine(name: "Untitled 3", savedText: "anything"), "untitled follows")
check(followsFirstLine(name: "Shopping", savedText: "# Shopping\nmilk"), "the saved title follows")
check(followsFirstLine(name: "Shopping 2", savedText: "Shopping"), "a numbered title follows")
check(!followsFirstLine(name: "Groceries", savedText: "Shopping"), "a name the user gave stays")
check(!followsFirstLine(name: "Shopping", savedText: ""), "no first line, no following")

let taken: Set = ["Untitled", "Untitled 2"]
equal(makeUniqueName("Untitled") { taken.contains($0) }, "Untitled 3")
equal(makeUniqueName("Plan") { taken.contains($0) }, "Plan")

equal(validNoteName("  Meeting notes \n"), "Meeting notes")
equal(validNoteName(" "), nil)
equal(validNoteName(".hidden"), nil)
equal(validNoteName("a/b"), nil)
equal(validNoteName("a:b"), nil)
// The limit is in UTF-8 bytes, and "\u{3042}" takes three.
check(validNoteName(String(repeating: "\u{3042}", count: 80)) != nil, "240 bytes is allowed")
equal(validNoteName(String(repeating: "\u{3042}", count: 81)), nil)

let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 7, hour: 15, minute: 30)
equal(conflictName("Plan", date: date.date!), "Plan (conflict 2026-11-07 1530)")

// MARK: - NoteStore

inFolder { folder in
    let store = NoteStore(folder: folder)
    let name = try store.create()
    equal(name, "Untitled")
    store.edit("hello")
    store.flush()
    equal(try contents(store, name), "hello")
    equal(try store.create(), "Untitled 2")
    equal(Set(store.list().map(\.name)), ["Untitled", "Untitled 2"])
}

// The file name follows the first line, stays unique, and stops following once renamed.
inFolder { folder in
    let store = NoteStore(folder: folder)
    var renames: [String] = []
    store.onRenamed = { renames.append("\($0) -> \($1)") }
    _ = try store.create()
    store.edit("# Shopping\nmilk")
    store.flush()
    equal(store.current, "Shopping")
    equal(try contents(store, "Shopping"), "# Shopping\nmilk")
    store.edit("Groceries\nmilk")
    store.flush()
    equal(store.current, "Groceries")
    equal(renames, ["Untitled -> Shopping", "Shopping -> Groceries"])

    _ = try store.create()
    store.edit("Groceries\neggs")
    store.flush()
    equal(store.current, "Groceries 2")

    equal(try store.rename("Groceries 2", to: "Weekly"), "Weekly")
    store.edit("Something else\neggs")
    store.flush()
    equal(store.current, "Weekly")
    equal(Set(store.list().map(\.name)), ["Groceries", "Weekly"])
}

// A file changed elsewhere is never overwritten; the text goes to a conflict copy.
inFolder { folder in
    let store = NoteStore(folder: folder)
    var renames: [(from: String, to: String)] = []
    store.onRenamed = { renames.append(($0, $1)) }
    _ = try store.create()
    store.edit("mine")
    store.flush()
    let name = try unwrapped(store.current)
    try Data("theirs!".utf8).write(to: store.url(name))
    store.edit("mine, again")
    store.flush()
    equal(try contents(store, name), "theirs!")
    guard let conflict = renames.last, conflict.from == name else { return fail("no conflict copy", #line) }
    check(conflict.to.hasPrefix("mine (conflict "), "conflict copy name: \(conflict.to)")
    equal(try contents(store, conflict.to), "mine, again")
    equal(store.current, conflict.to)
}

// A file deleted elsewhere is written again.
inFolder { folder in
    let store = NoteStore(folder: folder)
    let name = try store.create()
    try FileManager.default.removeItem(at: store.url(name))
    store.edit("still here")
    store.flush()
    equal(try contents(store, try unwrapped(store.current)), "still here")
}

// The contents a save replaces are kept in the backups folder.
inFolder { folder in
    let backups = folder.appendingPathComponent("Backups")
    let store = NoteStore(folder: folder.appendingPathComponent("Notes"), backups: backups)
    let backedUp = { () throws -> [String] in
        try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
            .map { try String(contentsOf: $0, encoding: .utf8) }.sorted()
    }
    _ = try store.create()
    store.edit("v1")
    store.flush()  // The file was empty, so there is nothing to keep.
    check(!FileManager.default.fileExists(atPath: backups.path), "no backup of an empty note")
    store.edit("v1\nmore")
    store.flush()
    equal(try backedUp(), ["v1"])
    store.edit("v1\nmore still")
    store.flush()  // Too soon after the last backup.
    equal(try backedUp(), ["v1"])
    store.backupInterval = 0
    store.edit("v1\nmore than ever")
    store.flush()
    equal(try backedUp().count, 2)
}

// Edits made elsewhere are picked up, but never over unsaved text.
inFolder { folder in
    let store = NoteStore(folder: folder)
    let name = try store.create()
    equal(store.reloadIfChanged(), nil)
    try Data("from outside".utf8).write(to: store.url(name))
    equal(store.reloadIfChanged(), "from outside")
    equal(store.reloadIfChanged(), nil)
    store.edit("unsaved")
    try Data("outside again".utf8).write(to: store.url(name))
    equal(store.reloadIfChanged(), nil)
    equal(store.text, "unsaved")
}

// Saving is still possible after a failed write, and the text stays unsaved until then.
inFolder { folder in
    let store = NoteStore(folder: folder)
    _ = try store.create()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    store.edit("kept")
    store.flush()
    check(store.hasUnsavedChanges, "unsaved after a failed write")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    store.flush()
    check(!store.hasUnsavedChanges, "saved once writing works again")
    equal(try contents(store, try unwrapped(store.current)), "kept")
}

inFolder { folder in
    let store = NoteStore(folder: folder)
    let first = try store.create()
    let second = try store.create()
    throwsError(NoteStoreError.exists) { try store.rename(first, to: second) }
    throwsError(NoteStoreError.invalidName) { try store.rename(first, to: "a/b") }
    equal(try store.rename(first, to: " Plan "), "Plan")
    equal(try store.rename("Plan", to: "plan"), "plan")  // A case-only change.
    equal(try store.rename(second, to: "Current"), "Current")
    equal(store.current, "Current")
    equal(Set(store.list().map(\.name)), ["plan", "Current"])
}

// Subfolders, other extensions, hidden files and links are not notes.
inFolder { folder in
    let manager = FileManager.default
    try manager.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
    for name in ["a.md", "b.txt", ".hidden.md", "sub/c.md"] {
        try Data().write(to: folder.appendingPathComponent(name))
    }
    try manager.createSymbolicLink(
        at: folder.appendingPathComponent("link.md"), withDestinationURL: folder.appendingPathComponent("a.md"))
    equal(NoteStore(folder: folder).list().map(\.name), ["a"])
}

// Text that isn't UTF-8 is not opened, and the footer says why.
inFolder { folder in
    let store = NoteStore(folder: folder)
    var status: String?
    store.onStatus = { status = $0 }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data([0xFF, 0xFE, 0xFD]).write(to: store.url("bad"))
    equal(store.open("bad"), nil)
    equal(store.current, nil)
    check(status != nil, "a status message")
}

if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("All checks passed")
