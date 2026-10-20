import XCTest

/// Uses the existing isolated QA partition on the connected physical iPhone. Never resets normal data.
@MainActor final class ArchitectureWorkflowTests: XCTestCase {
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testTrialCancelAndCompleteConfirmationSurviveRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CubicWorkCalendarQA", "-CubicWorkCalendarQAReset"]
        app.launch()
        XCTAssertTrue(app.buttons["行动"].waitForExistence(timeout: 20)); app.buttons["行动"].tap()
        let trial = app.buttons["action.trial.qa-drag"]
        XCTAssertTrue(trial.waitForExistence(timeout: 15)); trial.tap()
        XCTAssertTrue(app.navigationBars["投入时间试算"].waitForExistence(timeout: 10))
        capture("architecture-trial-initial")
        app.buttons["关闭"].tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "actions.choice.record.")).firstMatch.exists, "Closing trial must not create a choice")
        XCTAssertTrue(trial.waitForExistence(timeout: 10)); trial.tap()
        let preset = app.buttons["30 分钟"]
        XCTAssertTrue(preset.waitForExistence(timeout: 10)); preset.tap()
        let confirm = app.buttons["confirm-next-action"]
        for _ in 0..<8 where !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: confirm); waitForExpectations(timeout: 15)
        capture("architecture-trial-before-confirm")
        confirm.tap(withNumberOfTaps: 2, numberOfTouches: 1)
        // A minute boundary can legitimately require a new display, never an invisible auto-save.
        if app.staticTexts["结果已更新，请查看后再确认。"].waitForExistence(timeout: 3) {
            capture("architecture-trial-redisplayed")
            XCTAssertTrue(confirm.isEnabled); confirm.tap()
        }
        XCTAssertTrue(app.buttons["关闭"].waitForNonExistence(timeout: 15), "Confirmed operation dismisses its own sheet")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        capture("architecture-choice-saved")
        let record = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "actions.choice.record.")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        let choiceIdentity = record.identifier
        XCTAssertTrue(choiceIdentity.hasSuffix(".count.1"), "Double tap must save exactly one choice")
        record.tap()
        let evidence = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "choice.evidence.")).firstMatch
        XCTAssertTrue(evidence.waitForExistence(timeout: 10))
        let evidenceIdentity = evidence.identifier
        XCTAssertTrue(app.staticTexts["试算 30 分钟"].exists)
        capture("architecture-choice-evidence")
        app.terminate()
        app.launchArguments = ["-CubicWorkCalendarQA"]
        app.launch(); XCTAssertTrue(app.buttons["行动"].waitForExistence(timeout: 20)); app.buttons["行动"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "QA 拖拽时间块")).firstMatch.waitForExistence(timeout: 15))
        let restoredRecord = app.buttons[choiceIdentity]
        XCTAssertTrue(restoredRecord.waitForExistence(timeout: 10), "Reopen preserves exact choice ID and count")
        restoredRecord.tap()
        XCTAssertTrue(app.staticTexts[evidenceIdentity].waitForExistence(timeout: 10), "Reopen preserves full-precision evidence bytes")
        XCTAssertTrue(app.staticTexts["试算 30 分钟"].exists)
        capture("architecture-choice-reopened")
    }
}
