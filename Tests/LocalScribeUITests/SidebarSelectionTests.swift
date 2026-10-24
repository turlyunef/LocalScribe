import XCTest
@testable import LocalScribe

final class SidebarSelectionTests: XCTestCase {
    private let order = ["a", "b", "c", "d", "e"]

    func testCommandTogglesAndPlainClickResetsEvenOnSelectedRow() {
        var selection = SidebarSelection("a")
        selection.click("c", command: true, shift: false, order: order)
        XCTAssertEqual(selection.ids, ["a", "c"])
        selection.click("a", command: true, shift: false, order: order)
        XCTAssertEqual(selection.ids, ["c"])
        selection.click("e", command: true, shift: false, order: order)
        selection.click("c", command: false, shift: false, order: order)
        XCTAssertEqual(selection.ids, ["c"])
        selection.click("c", command: true, shift: false, order: order)
        XCTAssertTrue(selection.ids.isEmpty)
    }

    func testShiftIncludesEndpointsInBothDirectionsAndKeepsAnchorWhenShrinking() {
        var selection = SidebarSelection("d")
        selection.click("a", command: false, shift: true, order: order)
        XCTAssertEqual(selection.ids, ["a", "b", "c", "d"])
        selection.click("c", command: false, shift: true, order: order)
        XCTAssertEqual(selection.ids, ["c", "d"])
        selection.click("e", command: false, shift: true, order: order)
        XCTAssertEqual(selection.ids, ["d", "e"])
        XCTAssertEqual(selection.anchor, "d")
    }

    func testRangeUsesCurrentOrderAndFallsBackWhenAnchorIsHidden() {
        var selection = SidebarSelection("a")
        selection.click("c", command: false, shift: true, order: ["e", "a", "d", "c", "b"])
        XCTAssertEqual(selection.ids, ["a", "d", "c"])
        selection.click("b", command: false, shift: true, order: ["c", "b"])
        XCTAssertEqual(selection.ids, ["b"])
        XCTAssertEqual(selection.anchor, "b")
    }

    func testCommandShiftAddsRangeAndContextClickPreservesOnlySelectedSet() {
        var selection = SidebarSelection("a")
        selection.click("d", command: true, shift: false, order: order)
        selection.click("e", command: true, shift: true, order: order)
        XCTAssertEqual(selection.ids, ["a", "d", "e"])
        selection.contextClick("a")
        XCTAssertEqual(selection.ids, ["a", "d", "e"])
        selection.contextClick("b")
        XCTAssertEqual(selection.ids, ["b"])
        selection.retain(["a", "e"])
        XCTAssertTrue(selection.ids.isEmpty)
        XCTAssertNil(selection.anchor)
    }
}
