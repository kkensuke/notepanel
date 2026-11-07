import XCTest

@testable import NotepanelCore

final class NoteStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func contents(_ store: NoteStore, _ name: String) throws -> String {
        try String(contentsOf: store.url(name), encoding: .utf8)
    }

    func testCreateEditAndFlush() throws {
        let store = NoteStore(folder: folder)
        let name = try store.create()
        XCTAssertEqual(name, "Untitled")
        store.edit("hello")
        store.flush()
        XCTAssertEqual(try contents(store, name), "hello")
        XCTAssertEqual(try store.create(), "Untitled 2")
        XCTAssertEqual(Set(store.list().map(\.name)), ["Untitled", "Untitled 2"])
    }

    func testAFileChangedElsewhereIsNeverOverwritten() throws {
        let store = NoteStore(folder: folder)
        var conflict: (from: String, to: String)?
        store.onConflict = { conflict = ($0, $1) }
        let name = try store.create()
        store.edit("mine")
        store.flush()

        try Data("theirs!".utf8).write(to: store.url(name))
        store.edit("mine, again")
        store.flush()

        XCTAssertEqual(try contents(store, name), "theirs!")
        let copy = try XCTUnwrap(conflict?.to)
        XCTAssertEqual(conflict?.from, name)
        XCTAssertTrue(copy.hasPrefix("Untitled (conflict "))
        XCTAssertEqual(try contents(store, copy), "mine, again")
        XCTAssertEqual(store.current, copy)
    }

    func testAMissingFileIsRecreated() throws {
        let store = NoteStore(folder: folder)
        let name = try store.create()
        try FileManager.default.removeItem(at: store.url(name))
        store.edit("still here")
        store.flush()
        XCTAssertEqual(try contents(store, name), "still here")
    }

    func testReloadIfChanged() throws {
        let store = NoteStore(folder: folder)
        let name = try store.create()
        XCTAssertNil(store.reloadIfChanged())
        try Data("from outside".utf8).write(to: store.url(name))
        XCTAssertEqual(store.reloadIfChanged(), "from outside")
        XCTAssertNil(store.reloadIfChanged())
    }

    func testUnsavedTextIsNotReplacedByAReload() throws {
        let store = NoteStore(folder: folder)
        let name = try store.create()
        store.edit("unsaved")
        try Data("from outside".utf8).write(to: store.url(name))
        XCTAssertNil(store.reloadIfChanged())
        XCTAssertEqual(store.text, "unsaved")
    }

    func testRename() throws {
        let store = NoteStore(folder: folder)
        let first = try store.create()
        let second = try store.create()
        XCTAssertThrowsError(try store.rename(first, to: second)) {
            XCTAssertEqual($0 as? NoteStoreError, .exists)
        }
        XCTAssertThrowsError(try store.rename(first, to: "a/b")) {
            XCTAssertEqual($0 as? NoteStoreError, .invalidName)
        }
        XCTAssertEqual(try store.rename(first, to: " Plan "), "Plan")
        XCTAssertEqual(try store.rename("Plan", to: "plan"), "plan")
        XCTAssertEqual(try store.rename(second, to: "Current"), "Current")
        XCTAssertEqual(store.current, "Current")
        XCTAssertEqual(Set(store.list().map(\.name)), ["plan", "Current"])
    }

    func testListSkipsFilesThatAreNotNotes() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for name in ["a.md", "b.txt", ".hidden.md", "sub/c.md"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        try manager.createSymbolicLink(
            at: folder.appendingPathComponent("link.md"),
            withDestinationURL: folder.appendingPathComponent("a.md"))
        XCTAssertEqual(NoteStore(folder: folder).list().map(\.name), ["a"])
    }

    func testTextThatIsNotUTF8IsNotOpened() throws {
        let store = NoteStore(folder: folder)
        var status: String?
        store.onStatus = { status = $0 }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0xFD]).write(to: store.url("bad"))
        XCTAssertNil(store.open("bad"))
        XCTAssertNil(store.current)
        XCTAssertNotNil(status)
    }
}
