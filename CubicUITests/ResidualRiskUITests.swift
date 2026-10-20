import XCTest

/// Read-only native diagnosis of the ordinary workspace; no QA reset or mutations.
@MainActor final class ResidualRiskUITests: XCTestCase {
    private let cancelledResidualTitles = ["创建benchmark", "实现a1", "B：完成并行准备", "C：整合 A 的成果"]

    private func assertOldRemindersAbsent(_ app: XCUIApplication) {
        for title in cancelledResidualTitles {
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.exists,
                "Unreferenced cancelled history must not become a default scheduling reminder: \(title)")
        }
    }
    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
        print("RESIDUAL-DIAGNOSTIC \(name) texts=" + app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
    }

    func testReadOnlyArchivedProjectSchedulingReminders() throws {
        guard ProcessInfo.processInfo.environment["CUBIC_ARCHIVE_REVIEW"] == "1" else {
            throw XCTSkip("Ordinary workspace review requires CUBIC_ARCHIVE_REVIEW=1")
        }
        continueAfterFailure = false
        let baseline = ProcessInfo.processInfo.environment["CUBIC_ARCHIVE_REVIEW_BASELINE"] == "1"
        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["项目"].waitForExistence(timeout: 25))
        app.buttons["项目"].tap()
        let includeArchived = app.switches["projects.includeArchived"]
        XCTAssertTrue(includeArchived.waitForExistence(timeout: 10))
        includeArchived.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        capture("ordinary-archived-project-list", app: app)
        for names in [["项目1", "项目 1"], ["家庭财务复盘", "家庭账户复盘"]] {
            let project = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR label CONTAINS %@)", "projects.project.", names[0], names[1])).firstMatch
            for _ in 0..<5 where !project.isHittable { app.swipeUp() }
            XCTAssertTrue(project.isHittable, app.debugDescription); project.tap()
            let archive = app.buttons["project.archive"]
            for _ in 0..<5 where !archive.isHittable { app.swipeUp() }
            XCTAssertTrue(archive.isHittable, app.debugDescription)
            XCTAssertTrue(archive.label.contains("恢复显示"), "Expected already archived project: \(names[0])")
            capture("ordinary-archived-project-" + names[0], app: app)
            app.navigationBars["项目详情"].buttons.element(boundBy: 0).tap()
            for _ in 0..<5 where !includeArchived.isHittable { app.swipeDown() }
        }
        XCTAssertTrue(includeArchived.isHittable)
        includeArchived.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["行动"].tap()
        func assertArchivedNamesAbsent() {
            guard !baseline else { return }
            for name in ["项目1", "项目 1", "家庭财务复盘", "家庭账户复盘"] {
                XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch.exists,
                    "Archived project must not appear in default reminders: \(name)")
            }
            XCTAssertFalse(app.staticTexts["剩余工作还没确认清楚"].exists, "Calendar-only uncertainty must not imply unfinished archived work")
        }
        if !baseline { XCTAssertTrue(app.staticTexts["工作时间与日历占用待确认"].waitForExistence(timeout: 10)) }
        capture("ordinary-archive-actions-top", app: app)
        assertArchivedNamesAbsent()
        for page in 1...3 {
            app.swipeUp(); capture("ordinary-archive-actions-\(page)", app: app)
            assertArchivedNamesAbsent()
        }
        let overview = app.buttons["查看排期与待确认事项"].firstMatch
        for _ in 0..<3 where !overview.isHittable { app.swipeDown() }
        XCTAssertTrue(overview.isHittable, "Expected default planning overview with Calendar uncertainty")
        if overview.isHittable {
            overview.tap()
            capture("ordinary-archive-overview-top", app: app)
            assertArchivedNamesAbsent()
            for page in 1...2 {
                app.swipeUp(); capture("ordinary-archive-overview-\(page)", app: app)
                assertArchivedNamesAbsent()
            }
            app.navigationBars["排期与待确认事项"].buttons.element(boundBy: 0).tap()
        }
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["行动"].waitForExistence(timeout: 25))
        app.buttons["行动"].tap()
        for page in 0...2 {
            capture("ordinary-archive-restarted-\(page)", app: app)
            assertArchivedNamesAbsent()
            app.swipeUp()
        }
    }

    func testReadOnlyNormalWorkspaceResidualSchedulingRisks() throws {
        guard ProcessInfo.processInfo.environment["CUBIC_RESIDUAL_RISK_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Read-only acceptance of the explicitly selected ordinary mini workspace requires CUBIC_RESIDUAL_RISK_ACCEPTANCE=1")
        }
        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["行动"].waitForExistence(timeout: 25))
        app.buttons["行动"].tap()
        for title in ["1.2.1", "工作1.1.1", "工作1.1.2"] {
            XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 10))
        }
        capture("normal-actions-top", app: app)
        for page in 1...2 {
            app.swipeUp()
            capture("normal-actions-scroll-\(page)", app: app)
        }
        assertOldRemindersAbsent(app)
        XCTAssertTrue(app.staticTexts["推算中尚未实现的条件"].firstMatch.exists)
        let overview = app.buttons["查看排期与待确认事项"].firstMatch
        if overview.isHittable {
            overview.tap()
            capture("normal-risk-overview-top", app: app)
            for page in 1...1 {
                app.swipeUp()
                capture("normal-risk-overview-scroll-\(page)", app: app)
            }
            assertOldRemindersAbsent(app)
            XCTAssertTrue(app.staticTexts["工作时间与日历占用"].firstMatch.exists,
                "Valid Calendar capacity uncertainty must remain visible")
        }
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["行动"].waitForExistence(timeout: 25))
        app.buttons["行动"].tap()
        for _ in 0..<2 { app.swipeUp() }
        assertOldRemindersAbsent(app)
        XCTAssertTrue(app.staticTexts["推算中尚未实现的条件"].firstMatch.exists)
        capture("normal-actions-restarted-old-reminders-absent", app: app)
        let projects = app.buttons["项目"].firstMatch
        XCTAssertTrue(projects.isHittable, app.debugDescription)
        projects.tap()
        capture("normal-projects-top", app: app)
        let archived = app.switches["projects.includeArchived"].firstMatch
        XCTAssertTrue(archived.isHittable, app.debugDescription)
        XCTAssertEqual(archived.value as? String, "0")
        archived.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(archived.value as? String, "1")
        capture("normal-projects-including-archived-top", app: app)
        for page in 1...2 {
            app.swipeUp()
            capture("normal-projects-including-archived-scroll-\(page)", app: app)
        }
        for _ in 0..<4 where !archived.isHittable { app.swipeDown() }
        XCTAssertTrue(archived.isHittable)
        archived.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(archived.value as? String, "0")
        app.buttons["行动"].tap()
    }
}
