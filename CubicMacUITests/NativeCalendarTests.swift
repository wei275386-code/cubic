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
        // The week grid shows several timelines; open today's single-day timeline so the drop lands in today's capacity.
        let today = app.descendants(matching: .any)["calendar.week.day.\(Calendar.current.component(.day, from: Date()))"].firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 10))
        today.click()
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
        // QA capacity starts five minutes after launch; aim at a real future time read from the hour ticks.
        let target = try point(in: app, timeline: timeline, at: futureQuarterHour(after: 15))
        attach(app, named: "native-calendar-target")
        // On macOS `press` never delivers mouseDown to the AppKit drag source; `click(forDuration:thenDragTo:)` is the mouse drag.
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.3, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.5)
        let created = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in blocks.count > before }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [created], timeout: 10), .completed, "Drop must create a real time block")
        attach(app, named: "native-calendar-drop")

        // Pin the created block by identity so later queries cannot drift to another element.
        let blockID = blocks.firstMatch.identifier
        let block = app.buttons[blockID]
        block.click()
        let editStart = app.descendants(matching: .any)["calendar.block.start"].firstMatch
        XCTAssertTrue(editStart.waitForExistence(timeout: 5), "Click must open block editor")
        attach(app, named: "native-calendar-block-editor")
        app.typeKey(.escape, modifierFlags: [])
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: editStart)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed, "Escape must close block editor")
        sleep(1) // Let the sheet finish dismissing so the window takes mouse events again.

        // The label carries the block's time range; a real move must change it, not just shift layout.
        let originalLabel = block.label
        let center = block.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.click(forDuration: 0.3, thenDragTo: center.withOffset(CGVector(dx: 0, dy: 32)), withVelocity: .slow, thenHoldForDuration: 0.5)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in block.exists && block.label != originalLabel }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 10), .completed, "Dragging a block must move its time: \(originalLabel)")
        XCTAssertEqual(blocks.count, before + 1, "Moving must preserve one block identity")
        attach(app, named: "native-calendar-move")
        let movedLabel = block.label
        app.terminate()
        app.launchArguments = ["-CubicWorkCalendarQA"]
        app.launch(); app.activate()
        XCTAssertTrue(app.buttons["mac.syncStatus"].waitForExistence(timeout: 20))
        app.staticTexts["mac.sidebar.calendar"].click()
        // Back to today's single-day timeline: in week mode a block crossing midnight is drawn in both day columns.
        let todayAgain = app.descendants(matching: .any)["calendar.week.day.\(Calendar.current.component(.day, from: Date()))"].firstMatch
        if todayAgain.waitForExistence(timeout: 5) { todayAgain.click() }
        XCTAssertTrue(app.buttons[blockID].waitForExistence(timeout: 10), "Saved block identity must survive restart")
        XCTAssertEqual(app.buttons[blockID].label, movedLabel, "Moved time must survive restart")
        XCTAssertEqual(app.buttons.matching(blockPredicate).count, before + 1)
        attach(app, named: "native-calendar-restart")
    }

    private func futureQuarterHour(after minutes: Double) -> Date {
        let seconds = Date().addingTimeInterval(minutes * 60).timeIntervalSince1970
        return Date(timeIntervalSince1970: ceil(seconds / 900) * 900)
    }

    private func tickDate(_ label: String) -> Date? {
        let parts = label.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())
    }

    /// Scrolls the timeline until `date` is on screen and returns its coordinate in the first lane.
    private func point(in app: XCUIApplication, timeline: XCUIElement, at date: Date) throws -> XCUICoordinate {
        let zero = app.descendants(matching: .any)["calendar.hour.0"].firstMatch
        let one = app.descendants(matching: .any)["calendar.hour.1"].firstMatch
        XCTAssertTrue(zero.waitForExistence(timeout: 5) && one.exists, "Hour ticks must exist")
        // macOS exposes static text through value rather than label.
        let text = zero.label.isEmpty ? (zero.value as? String ?? "") : zero.label
        let start = try XCTUnwrap(tickDate(text), "Unparseable first tick \(text)")
        let window = app.windows.firstMatch.frame
        func y() -> CGFloat {
            let perMinute = (one.frame.midY - zero.frame.midY) / 60
            return zero.frame.midY + CGFloat(date.timeIntervalSince(start) / 60) * perMinute
        }
        for _ in 0..<12 where y() > window.maxY - 80 { timeline.scroll(byDeltaX: 0, deltaY: -200) }
        for _ in 0..<12 where y() < window.minY + 160 { timeline.scroll(byDeltaX: 0, deltaY: 200) }
        let targetY = y()
        XCTAssertTrue((window.minY + 120...window.maxY - 40).contains(targetY), "Target \(date) must be visible: y=\(targetY) window=\(window)")
        // The application element has no finite frame on macOS; anchor to the window instead.
        return app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: timeline.frame.minX + 120 - window.minX, dy: targetY - window.minY))
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
