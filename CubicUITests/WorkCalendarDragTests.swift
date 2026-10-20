import XCTest

/// Real iOS UIDragSession/UIDropSession driven by touch, never model injection.
@MainActor final class WorkCalendarDragTests: XCTestCase {
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func reveal(_ app: XCUIApplication, target: XCUIElement, searchUp: Bool = false) {
        for _ in 0..<16 {
            if target.exists && target.isHittable && target.frame.minY > 145 && target.frame.maxY < app.frame.height - 130 { return }
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            let delta = (target.exists && target.frame.minY < 145) || (!target.exists && searchUp) ? 140.0 : -140.0
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: delta)), withVelocity: .slow, thenHoldForDuration: 0)
        }
    }
    /// 首个小时刻度标签（如 "0:00"）映射到当天对应时刻，得到时间轴真实起点。
    /// 不能假设 rangeStart = 当前整点前一小时：跨零点时它会被钳到当天 0:00。
    private func axisStartDate(_ label: String) -> Date? {
        let parts = label.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())
    }
    private func blockStartDate(_ block: XCUIElement) -> Date? {
        let fields = block.label.split(separator: "，")
        guard fields.count > 1, let start = fields[1].split(separator: "–").first else { return nil }
        return axisStartDate(String(start))
    }
    private func futureQuarterHour(after minutes: Double = 15) -> Date {
        let seconds = Date().addingTimeInterval(minutes * 60).timeIntervalSince1970
        return Date(timeIntervalSince1970: ceil(seconds / 900) * 900)
    }
    private func createNativeBlock(_ app: XCUIApplication, itemID: String = "qa-delete", at start: Date) throws -> XCUIElement {
        let card = app.buttons["calendar.drag.item.\(itemID)"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let zero = app.descendants(matching: .any)["calendar.hour.0"].firstMatch
        let one = app.descendants(matching: .any)["calendar.hour.1"].firstMatch
        let axisStart = try XCTUnwrap(axisStartDate(zero.label))
        let scale = (one.frame.midY - zero.frame.midY) / 60
        let targetY = zero.frame.midY + start.timeIntervalSince(axisStart) / 60 * scale
        XCTAssertGreaterThan(targetY, 150)
        XCTAssertLessThan(targetY, app.frame.height - 125, "Fixture drop stays above the scroll edge")
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 1.2, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 200, dy: targetY)), withVelocity: .slow, thenHoldForDuration: 0.3)
        let block = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendar.block.")).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertEqual(try XCTUnwrap(blockStartDate(block)), start)
        return block
    }
    func testTopLayoutAndCancelledLift() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CubicWorkCalendarQA", "-CubicWorkCalendarQAReset"]
        app.launch()
        XCTAssertTrue(app.buttons["行动"].waitForExistence(timeout: 20))
        app.buttons["行动"].tap()
        XCTAssertFalse(app.staticTexts["现在可以做什么？"].exists)
        XCTAssertFalse(app.staticTexts["可开始"].exists)
        capture("qa-actions-top-layout")
        app.buttons["日历"].tap()
        let card = app.buttons["calendar.drag.item.qa-drag"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.isHittable, "Time block rail must be on the first screen")
        let axis = app.descendants(matching: .any)["calendar.timeline"].firstMatch
        XCTAssertTrue(axis.exists)
        XCTAssertLessThan(card.frame.minY, axis.frame.minY)
        XCTAssertFalse(app.staticTexts["可能的工作安排"].exists)
        print("QA-LAYOUT screen=\(app.frame) rail=\(card.frame) timeline=\(axis.frame)")
        capture("qa-calendar-top-layout")
        let source = card.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let outside = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 110, dy: 265))
        source.press(forDuration: 1.2, thenDragTo: outside, withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendar.block.")).count, 0)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertTrue(card.isHittable)
        capture("qa-cancelled-lift-card-restored")
        card.tap()
        XCTAssertTrue(app.textFields["calendar.block.minutes"].waitForExistence(timeout: 5), "Cancelled source remains tap editable")
        capture("qa-cancelled-source-tap-editor")
    }
    func testAppleCalendarReadOnlyReference() throws {
        let calendarApp = XCUIApplication(bundleIdentifier: "com.apple.mobilecal")
        calendarApp.activate()
        XCTAssertTrue(calendarApp.wait(for: .runningForeground, timeout: 10))
        capture("qa-apple-calendar-read-only-reference")
        // No event creation, editing, deletion or drag of system events.
        calendarApp.terminate()
    }
    func testNativeDragEdgeAutoscroll() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CubicWorkCalendarQA", "-CubicWorkCalendarQAReset"]
        app.launch()
        XCTAssertTrue(app.buttons["日历"].waitForExistence(timeout: 20))
        app.buttons["日历"].tap()
        let block = try createNativeBlock(app, at: futureQuarterHour())
        let id = block.identifier, originalLabel = block.label
        var initialHours: [Int: (label: String, midY: CGFloat)] = [:]
        for index in 0...12 {
            let tick = app.descendants(matching: .any)["calendar.hour.\(index)"].firstMatch
            if tick.exists { initialHours[index] = (tick.label, tick.frame.midY) }
        }
        XCTAssertGreaterThan(initialHours.count, 3)
        capture("run3-edge-before-valid-block")
        let edge = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 200, dy: app.frame.height - 105))
        block.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1.2, thenDragTo: edge, withVelocity: .slow, thenHoldForDuration: 3.5)
        capture("run3-edge-after-3_5-second-hold")
        if app.alerts.firstMatch.exists { app.alerts.buttons["知道了"].tap() }
        var visibleHours: [(index: Int, midY: CGFloat)] = []
        for index in initialHours.keys.sorted() {
            let tick = app.descendants(matching: .any)["calendar.hour.\(index)"].firstMatch
            if tick.exists {
                let frame = tick.frame
                if frame.minY > 145 && frame.maxY < app.frame.height - 100 {
                    XCTAssertEqual(tick.label, initialHours[index]?.label)
                    visibleHours.append((index, frame.midY))
                }
            }
        }
        let lowerTick = try XCTUnwrap(visibleHours.last, "Lower axis must remain on screen after the long edge hold")
        let lastIndex = try XCTUnwrap(initialHours.keys.max())
        XCTAssertGreaterThanOrEqual(lowerTick.index, lastIndex - 1)
        let before = try XCTUnwrap(initialHours[lowerTick.index]).midY
        print("QA-FIXED-EDGE index=\(lowerTick.index) before=\(before) after=\(lowerTick.midY) displacement=\(before - lowerTick.midY)")
        XCTAssertGreaterThan(before - lowerTick.midY, 20)
        let project = app.descendants(matching: .any)["calendar.project.qa-project"].firstMatch
        XCTAssertFalse(project.exists && project.isHittable, "Edge hold must not scroll into project details")
        XCTAssertEqual(app.buttons[id].label, originalLabel, "Out-of-capacity edge hold must preserve the valid original")

        // A normal swipe proves that all temporary scroll locks were released.
        let swipeTick = try XCTUnwrap(visibleHours.first(where: { $0.index >= 1 && $0.index <= 3 }))
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 140)), withVelocity: .slow, thenHoldForDuration: 0)
        let tickAfterSwipe = app.descendants(matching: .any)["calendar.hour.\(swipeTick.index)"].firstMatch
        XCTAssertTrue(tickAfterSwipe.exists)
        print("QA-FIXED-SCROLL-RESTORED index=\(swipeTick.index) before=\(swipeTick.midY) after=\(tickAfterSwipe.frame.midY)")
        XCTAssertGreaterThan(tickAfterSwipe.frame.midY - swipeTick.midY, 30)
        capture("run3-edge-normal-swipe-restored")

        // A second real drag lands inside the fixture's available interval.
        let moved = app.buttons[id]
        let originalStart = try XCTUnwrap(blockStartDate(moved))
        let zero = app.descendants(matching: .any)["calendar.hour.0"].firstMatch
        let one = app.descendants(matching: .any)["calendar.hour.1"].firstMatch
        let scale = (one.frame.midY - zero.frame.midY) / 60
        let source = moved.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        source.press(forDuration: 1.2, thenDragTo: source.withOffset(CGVector(dx: 0, dy: 15 * scale)), withVelocity: .slow, thenHoldForDuration: 0.3)
        let changed = NSPredicate { _, _ in moved.exists && moved.label != originalLabel }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 10), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertEqual(try XCTUnwrap(blockStartDate(moved)).timeIntervalSince(originalStart), 900, accuracy: 0.1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendar.block.")).count, 1)
        capture("run3-edge-second-drag-valid-save")
        let tick = app.descendants(matching: .any)["calendar.hour.1"].firstMatch
        let yBeforeSecondSwipe = tick.frame.midY
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -100)), withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertGreaterThan(yBeforeSecondSwipe - tick.frame.midY, 20, "Scroll remains enabled after the second drop")
        capture("run3-edge-second-drop-scroll-restored")
    }
    func testFifteenMinuteBlockGeometry() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CubicWorkCalendarQA", "-CubicWorkCalendarQAReset"]
        app.launch()
        XCTAssertTrue(app.buttons["日历"].waitForExistence(timeout: 20))
        app.buttons["日历"].tap()
        let first = try createNativeBlock(app, at: futureQuarterHour())
        let id = first.identifier
        first.tap()
        let minutes = app.textFields["calendar.block.minutes"]
        XCTAssertTrue(minutes.waitForExistence(timeout: 5))
        minutes.tap()
        minutes.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "15")
        app.buttons["calendar.block.editor.save"].firstMatch.tap()
        let block = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendar.block.")).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 10))
        let zero = app.descendants(matching: .any)["calendar.hour.0"].firstMatch
        let one = app.descendants(matching: .any)["calendar.hour.1"].firstMatch
        let pointsPerMinute = (one.frame.midY - zero.frame.midY) / 60
        let start = try XCTUnwrap(blockStartDate(block))
        let axisStart = try XCTUnwrap(axisStartDate(zero.label))
        let expectedTop = zero.frame.midY + start.timeIntervalSince(axisStart) / 60 * pointsPerMinute
        capture("run3-fifteen-minute-block-geometry")
        print("QA-SHORT-GEOMETRY block=\(block.frame) label=\(block.label) hourZero=\(zero.frame) hourOne=\(one.frame) expectedHeight=\(15 * pointsPerMinute - 1)")
        XCTAssertFalse(app.buttons["calendar.drag.item.qa-delete"].exists)
        XCTAssertEqual(block.frame.height, 15 * pointsPerMinute - 1, accuracy: 1.5, "15-minute block must use the same time scale as hour labels")
        XCTAssertEqual(block.frame.minY, expectedTop, accuracy: 0.75, "Short block top matches the time-axis coordinate")
        let originalLabel = block.label
        let source = block.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        source.press(forDuration: 1.2, thenDragTo: source.withOffset(CGVector(dx: 0, dy: 15 * pointsPerMinute)), withVelocity: .slow, thenHoldForDuration: 0.3)
        let moved = app.buttons[id]
        let changed = NSPredicate { _, _ in moved.exists && moved.label != originalLabel }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 10), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertEqual(try XCTUnwrap(blockStartDate(moved)).timeIntervalSince(start), 900, accuracy: 0.1)
        XCTAssertEqual(moved.frame.height, 14, accuracy: 0.75)
        XCTAssertEqual(moved.frame.minY, expectedTop + 15 * pointsPerMinute, accuracy: 0.75)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendar.block.")).count, 1)
        print("QA-FIXED-SHORT-MOVE id=\(id) originalStart=\(start) movedStart=\(try XCTUnwrap(blockStartDate(moved))) frame=\(moved.frame) expectedTop=\(expectedTop + 15 * pointsPerMinute)")
        capture("run3-fifteen-minute-block-moved-15-minutes")
    }
    func testDeleteDisappearsFromCalendarProjectAndRailAfterRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CubicWorkCalendarQA", "-CubicWorkCalendarQAReset"]
        app.launch()
        XCTAssertTrue(app.buttons["日历"].waitForExistence(timeout: 20))
        app.buttons["日历"].tap()
        let project = app.descendants(matching: .any)["calendar.project.qa-project"].firstMatch
        reveal(app, target: project)
        XCTAssertTrue(project.exists)
        project.tap()
        let work = app.buttons["calendar.project.item.qa-delete"]
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        work.tap()
        let delete = app.buttons["work.delete"]
        reveal(app, target: delete)
        XCTAssertTrue(delete.isHittable)
        XCTAssertFalse(app.buttons["work.cancel"].exists)
        XCTAssertFalse(app.buttons["work.archive"].exists)
        delete.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        capture("device-delete-confirmation")
        app.alerts.buttons["work.delete.confirm"].firstMatch.tap()
        let absent = NSPredicate { _, _ in !work.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: absent, object: nil)], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["calendar.project.item.qa-drag"].exists)
        capture("device-calendar-project-after-deletion")
        let rail = app.buttons["calendar.drag.item.qa-drag"]
        reveal(app, target: rail, searchUp: true)
        XCTAssertTrue(rail.exists)
        XCTAssertFalse(app.buttons["calendar.drag.item.qa-delete"].exists)
        capture("device-calendar-rail-after-deletion")
        app.terminate()
        app.launchArguments = ["-CubicWorkCalendarQA"]
        app.launch()
        XCTAssertTrue(app.buttons["日历"].waitForExistence(timeout: 20))
        app.buttons["日历"].tap()
        reveal(app, target: project)
        project.tap()
        XCTAssertTrue(app.buttons["calendar.project.item.qa-drag"].exists)
        XCTAssertFalse(app.buttons["calendar.project.item.qa-delete"].exists)
        capture("device-deletion-persisted-after-relaunch")
    }
    func testNativeDragCreatesMovesRejectsInvalidAndPersistsTimeBlock() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CubicWorkCalendarQA", "-CubicWorkCalendarQAReset"]
        app.launch()
        XCTAssertTrue(app.buttons["日历"].waitForExistence(timeout: 20))
        app.buttons["日历"].tap()
        let card = app.buttons["calendar.drag.item.qa-delete"]
        reveal(app, target: card)
        XCTAssertTrue(card.isHittable, "Real draggable card must be visible")
        capture("before-native-drag")
        let hourZero = app.descendants(matching: .any)["calendar.hour.0"].firstMatch
        let hourOne = app.descendants(matching: .any)["calendar.hour.1"].firstMatch
        XCTAssertTrue(hourZero.exists && hourOne.exists, "Axis hierarchy: \(app.debugDescription)")
        // 时间轴每小时高度不是常量假设：从真实小时刻度推导，避免改版后坐标静默落到过去而被正确拒绝。
        let pointsPerMinute = (hourOne.frame.midY - hourZero.frame.midY) / 60
        XCTAssertGreaterThan(pointsPerMinute, 0, "Axis hour rows must be ordered: \(hourZero.frame) \(hourOne.frame)")
        let axisStart = try XCTUnwrap(axisStartDate(hourZero.label), "无法解析首个刻度：\(hourZero.label)")
        let future = futureQuarterHour(after: 20)
        let y = future.timeIntervalSince(axisStart) / 60 * pointsPerMinute
        XCTAssertGreaterThan(y, 0, "目标时间应位于轴内：axisStart=\(axisStart) future=\(future)")
        let target = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 200, dy: hourZero.frame.midY + y))
        print("NATIVE-DRAG source=\(card.frame) axis=\(hourZero.frame) hourOne=\(hourOne.frame) axisStart=\(axisStart) pointsPerMinute=\(pointsPerMinute) targetY=\(hourZero.frame.midY + y)")
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 1.2, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.5)
        capture("after-native-drag-attempt")
        let blockQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendar.block."))
        XCTAssertTrue(blockQuery.firstMatch.waitForExistence(timeout: 12), "Native drop must persist a block; hierarchy: \(app.debugDescription)")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Valid drop must save")
        let block = blockQuery.firstMatch
        let id = block.identifier
        let originalLabel = block.label
        XCTAssertEqual(blockQuery.count, 1)
        XCTAssertFalse(card.exists, "Fully scheduled work must not offer a fictitious extra rail minute")
        let expectedTop = hourZero.frame.midY + future.timeIntervalSince(axisStart) / 60 * pointsPerMinute
        print("QA-HOUR-ALIGNMENT blockTop=\(block.frame.minY) labelCentreExpected=\(expectedTop) delta=\(block.frame.minY - expectedTop)")
        XCTAssertEqual(block.frame.minY, expectedTop, accuracy: 1.5, "Snapped block top aligns with the hour-label time scale")
        capture("native-drop-created-time-block")
        let moveTarget = block.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 15 * pointsPerMinute))
        block.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1.2, thenDragTo: moveTarget, withVelocity: .slow, thenHoldForDuration: 0.5)
        let moved = app.buttons[id]
        let changed = NSPredicate { _, _ in moved.exists && moved.label != originalLabel }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 12), .completed)
        XCTAssertEqual(blockQuery.count, 1, "Move preserves reservation identity")
        let movedLabel = moved.label
        capture("native-drag-moved-time-block")

        // Native drag into the past/outside capacity: original reservation stays unchanged.
        let invalidTarget = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 200, dy: hourZero.frame.midY + 10 * pointsPerMinute))
        moved.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1.2, thenDragTo: invalidTarget, withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 12))
        capture("invalid-native-drop-rejected")
        app.alerts.buttons["知道了"].tap()
        XCTAssertEqual(app.buttons[id].label, movedLabel)
        XCTAssertEqual(blockQuery.count, 1)

        let otherCard = app.buttons["calendar.drag.item.qa-drag"]
        XCTAssertTrue(otherCard.isHittable)
        let occupiedTarget = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: moved.frame.midX, dy: moved.frame.minY + 2))
        otherCard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 1.2, thenDragTo: occupiedTarget, withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 12), "Occupied drop must be rejected")
        capture("qa-occupied-native-drop-rejected")
        app.alerts.buttons["知道了"].tap()
        XCTAssertEqual(app.buttons[id].label, movedLabel)
        XCTAssertEqual(blockQuery.count, 1)
        XCTAssertTrue(otherCard.isHittable)
        capture("qa-rejected-card-opacity-restored")

        app.terminate()
        app.launchArguments = ["-CubicWorkCalendarQA"]
        app.launch()
        XCTAssertTrue(app.buttons["日历"].waitForExistence(timeout: 20))
        app.buttons["日历"].tap()
        reveal(app, target: app.buttons[id])
        XCTAssertTrue(app.buttons[id].exists)
        XCTAssertEqual(app.buttons[id].label, movedLabel, "Dragged block survives process restart")
        XCTAssertEqual(blockQuery.count, 1)
        capture("native-drag-persisted-after-relaunch")

        // The same native block must remain tap-editable after drag/restart.
        app.buttons[id].tap()
        let duration = app.textFields["calendar.block.minutes"]
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        duration.tap()
        duration.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "15")
        capture("device-time-block-precise-editor")
        app.buttons["calendar.block.editor.save"].firstMatch.tap()
        let edited = NSPredicate { _, _ in app.buttons[id].exists && app.buttons[id].label != movedLabel }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: edited, object: nil)], timeout: 12), .completed)
        XCTAssertEqual(blockQuery.count, 1)
        capture("device-time-block-duration-updated")
        XCTAssertFalse(app.buttons["calendar.drag.item.qa-delete"].exists, "A 15-minute block hides a work with 30 minutes remaining")
        print("QA-PARTIAL block=\(app.buttons[id].label) candidateAbsent=\(!app.buttons["calendar.drag.item.qa-delete"].exists)")
        app.buttons[id].tap()
        let remove = app.buttons["calendar.block.removeNow"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        let removed = NSPredicate { _, _ in !app.buttons[id].exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: removed, object: nil)], timeout: 12), .completed)
        XCTAssertEqual(blockQuery.count, 0)
        XCTAssertTrue(app.buttons["calendar.drag.item.qa-delete"].exists, "Removing an arrangement preserves the work")
        capture("device-time-block-removed-work-retained")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["日历"].waitForExistence(timeout: 20))
        app.buttons["日历"].tap()
        reveal(app, target: app.buttons["calendar.drag.item.qa-delete"])
        XCTAssertEqual(blockQuery.count, 0)
        capture("device-time-block-removal-persisted")
    }
}
