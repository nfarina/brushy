import AppKit
import XCTest

/// View menu toggles: wired to their shortcuts, flipping store state, and
/// showing it as a checkmark through `validateUserInterfaceItem`.
final class ViewMenuTests: XCTestCase {
    private func item(for action: Selector, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.action == action { return item }
            if let submenu = item.submenu, let found = self.item(for: action, in: submenu) { return found }
        }
        return nil
    }

    func testShowSelectionEdgesIsShiftCommandH() throws {
        let menu = MainMenuBuilder.build()
        let edges = try XCTUnwrap(item(for: #selector(BrushyDocument.toggleSelectionEdges(_:)), in: menu))
        XCTAssertEqual(edges.keyEquivalent, "h")
        XCTAssertEqual(edges.keyEquivalentModifierMask, [.command, .shift])
    }

    func testTogglingSelectionEdgesUpdatesTheCheckmark() {
        let document = BrushyDocument()
        let menuItem = NSMenuItem(title: "Show Selection Edges",
                                  action: #selector(BrushyDocument.toggleSelectionEdges(_:)),
                                  keyEquivalent: "h")
        XCTAssertTrue(document.store.selectionEdgesVisible, "ants show by default")
        XCTAssertTrue(document.validateUserInterfaceItem(menuItem))
        XCTAssertEqual(menuItem.state, .on)

        document.toggleSelectionEdges(nil)
        XCTAssertFalse(document.store.selectionEdgesVisible)
        XCTAssertTrue(document.validateUserInterfaceItem(menuItem))
        XCTAssertEqual(menuItem.state, .off)
    }
}
