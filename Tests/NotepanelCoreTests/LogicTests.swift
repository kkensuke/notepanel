import CoreGraphics
import XCTest

@testable import NotepanelCore

final class LogicTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testFittedFrameKeepsTheTopEdge() {
        let frame = CGRect(x: 100, y: 500, width: 400, height: 200)
        let fitted = fittedFrame(frame, height: 300, minHeight: 120, maxHeight: 640, in: screen)
        XCTAssertEqual(fitted, CGRect(x: 100, y: 400, width: 400, height: 300))
    }

    func testFittedFrameMovesUpAtTheBottomOfTheScreen() {
        let frame = CGRect(x: 0, y: 100, width: 400, height: 200)
        let fitted = fittedFrame(frame, height: 500, minHeight: 120, maxHeight: 640, in: screen)
        XCTAssertEqual(fitted, CGRect(x: 0, y: 0, width: 400, height: 500))
    }

    func testFittedFrameClampsTheHeight() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        XCTAssertEqual(fittedFrame(frame, height: 5000, minHeight: 120, maxHeight: 640, in: screen).height, 640)
        XCTAssertEqual(fittedFrame(frame, height: 10, minHeight: 120, maxHeight: 640, in: screen).height, 120)
        XCTAssertEqual(fittedFrame(frame, height: 900, minHeight: 120, maxHeight: 2000, in: screen).height, 800)
    }

    func testDisplayTitle() {
        XCTAssertEqual(displayTitle(name: "Untitled 2", text: "\n\n# Shopping **list**\n- milk"), "Shopping list")
        XCTAssertEqual(displayTitle(name: "Untitled", text: "- [ ] Call Sam"), "Call Sam")
        XCTAssertEqual(displayTitle(name: "Untitled", text: "1. First"), "First")
        XCTAssertEqual(displayTitle(name: "Untitled", text: "  \n"), "Untitled")
        XCTAssertEqual(displayTitle(name: "Untitled ideas", text: "first"), "Untitled ideas")
        XCTAssertEqual(displayTitle(name: "Plan", text: "# Other"), "Plan")
    }

    func testMakeUniqueName() {
        let taken: Set = ["Untitled", "Untitled 2"]
        XCTAssertEqual(makeUniqueName("Untitled") { taken.contains($0) }, "Untitled 3")
        XCTAssertEqual(makeUniqueName("Plan") { taken.contains($0) }, "Plan")
    }

    func testValidNoteName() {
        XCTAssertEqual(validNoteName("  Meeting notes \n"), "Meeting notes")
        XCTAssertNil(validNoteName(" "))
        XCTAssertNil(validNoteName(".hidden"))
        XCTAssertNil(validNoteName("a/b"))
        XCTAssertNil(validNoteName("a:b"))
        // The limit is in UTF-8 bytes, and "\u{3042}" takes three.
        XCTAssertNotNil(validNoteName(String(repeating: "\u{3042}", count: 80)))
        XCTAssertNil(validNoteName(String(repeating: "\u{3042}", count: 81)))
    }

    func testConflictName() {
        let date = DateComponents(
            calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 7, hour: 15, minute: 30
        ).date!
        XCTAssertEqual(conflictName("Plan", date: date), "Plan (conflict 2026-11-07 1530)")
    }
}
