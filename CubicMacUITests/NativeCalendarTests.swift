import XCTest

/// Uses the real AppKit drag session. No simulated sync transport or Simulator.
@MainActor final class NativeCalendarTests: XCTestCase {
    func testNativeCalendarCardDropBlockClickAndMove() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Reset only CubicQA storage/defaults. Production and remote files are untouched.
        app.launchArguments = ["-CubicWorkCalendarQA", "-CubicWorkCalendarQAReset"]
        app.launch()
        defer {
            app.terminate()
            app.launchArguments = []
            app.launch()
        }
        app.activate()
        XCTAssertTrue(app.buttons["mac.syncStatus"].waitForExistence(timeout: 20), "Workspace boot must complete before commands")
        let calendar = app.staticTexts["mac.sidebar.calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        calendar.click()
        attach(app, named: "native-calendar-before-drag")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "native-calendar-accessibility"; tree.lifetime = .keepAlways; add(tree)

        let source = app.descendants(matching: .any)["calendar.drag.item.qa-delete"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 15), "QA drag card must be visible")
        XCTAssertTrue(source.isHittable, "Source card must be on screen before native drag")
        let timeline = app.descendants(matching: .any)["calendar.timeline"].firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 5), "Native timeline must exist")
        let blockPredicate = NSPredicate(format: "identifier BEGINSWITH %@", "calendar.block.")
        let blocks = app.buttons.matching(blockPredicate)
        let before = blocks.count
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)))
        let created = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in blocks.count > before }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [created], timeout: 10), .completed, "Drop must create a real time block")
        attach(app, named: "native-calendar-drop")

        let block = blocks.firstMatch
        block.click()
        let editStart = app.descendants(matching: .any)["calendar.block.start"].firstMatch
        XCTAssertTrue(editStart.waitForExistence(timeout: 5), "Click must open block editor")
        attach(app, named: "native-calendar-block-editor")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(editStart.waitForExistence(timeout: 1), "Escape must close block editor")

        let originalFrame = block.frame
        block.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: block.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 30)))
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(block.frame.minY - originalFrame.minY) > 5
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 10), .completed, "Dragging a block must move its time")
        XCTAssertEqual(blocks.count, before + 1, "Moving must preserve one block identity")
        attach(app, named: "native-calendar-move")
        let blockID = block.identifier
        let movedLabel = block.label
        app.terminate()
        app.launchArguments = ["-CubicWorkCalendarQA"]
        app.launch(); app.activate()
        XCTAssertTrue(app.buttons["mac.syncStatus"].waitForExistence(timeout: 20))
        app.staticTexts["mac.sidebar.calendar"].click()
        XCTAssertTrue(app.buttons[blockID].waitForExistence(timeout: 10), "Saved block identity must survive restart")
        XCTAssertEqual(app.buttons[blockID].label, movedLabel, "Moved time must survive restart")
        XCTAssertEqual(app.buttons.matching(blockPredicate).count, before + 1)
        attach(app, named: "native-calendar-restart")
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
