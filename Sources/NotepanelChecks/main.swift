// Assertion-based checks for NotepanelCore. Run with `swift run NotepanelChecks`.
// They stand in for XCTest, which the Command Line Tools don't include.
import CoreGraphics
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

func contents(_ store: NoteStore, _ name: String) throws -> String {
    try String(contentsOf: store.url(name), encoding: .utf8)
}

// MARK: - Window fitting

let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
let window = CGRect(x: 0, y: 0, width: 400, height: 200)

// The top edge stays put while the window grows.
equal(
    fittedFrame(CGRect(x: 100, y: 500, width: 400, height: 200), height: 300, minHeight: 120, maxHeight: 640, in: screen),
    CGRect(x: 100, y: 400, width: 400, height: 300))
// At the bottom of the screen, the window moves up instead.
equal(
    fittedFrame(CGRect(x: 0, y: 100, width: 400, height: 200), height: 500, minHeight: 120, maxHeight: 640, in: screen),
    CGRect(x: 0, y: 0, width: 400, height: 500))
// The height stays within the limits and the screen.
equal(fittedFrame(window, height: 5000, minHeight: 120, maxHeight: 640, in: screen).height, 640)
equal(fittedFrame(window, height: 10, minHeight: 120, maxHeight: 640, in: screen).height, 120)
equal(fittedFrame(window, height: 900, minHeight: 120, maxHeight: 2000, in: screen).height, 800)

// MARK: - Names

equal(displayTitle(name: "Untitled 2", text: "\n\n# Shopping **list**\n- milk"), "Shopping list")
equal(displayTitle(name: "Untitled", text: "- [ ] Call Sam"), "Call Sam")
equal(displayTitle(name: "Untitled", text: "1. First"), "First")
equal(displayTitle(name: "Untitled", text: "  \n"), "Untitled")
equal(displayTitle(name: "Untitled ideas", text: "first"), "Untitled ideas")
equal(displayTitle(name: "Plan", text: "# Other"), "Plan")

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

// A file changed elsewhere is never overwritten; the text goes to a conflict copy.
inFolder { folder in
    let store = NoteStore(folder: folder)
    var conflict: (from: String, to: String)?
    store.onConflict = { conflict = ($0, $1) }
    let name = try store.create()
    store.edit("mine")
    store.flush()
    try Data("theirs!".utf8).write(to: store.url(name))
    store.edit("mine, again")
    store.flush()
    equal(try contents(store, name), "theirs!")
    guard let conflict else { return fail("no conflict copy", #line) }
    equal(conflict.from, name)
    check(conflict.to.hasPrefix("Untitled (conflict "), "conflict copy name: \(conflict.to)")
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
    equal(try contents(store, name), "still here")
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
