import XCTest

/// Drives the Mac app through local saving, relaunch, settings and connecting a sync folder.
/// Pass an existing empty folder for the folder step, e.g.
/// `TEST_RUNNER_CUBIC_SYNC_FOLDER=/tmp/cubic-sync xcodebuild test -scheme CubicMac -only-testing:CubicMacUITests/MacSyncSmokeTests`.
@MainActor final class MacSyncSmokeTests: XCTestCase {
    private func shot(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-tree"; tree.lifetime = .keepAlways; add(tree)
    }
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        let scroll = app.sheets.firstMatch.scrollViews.firstMatch
        for _ in 0..<20 where !(element.exists && element.isHittable) { scroll.scroll(byDeltaX: 0, deltaY: -200) }
    }
    /// macOS exposes SwiftUI text as `value`; iOS uses `label`.
    private func text(_ app: XCUIApplication, _ string: String) -> XCUIElement {
        app.windows.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ OR value == %@", string, string)).firstMatch
    }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch(); app.activate()
        XCTAssertTrue(app.buttons["mac.syncStatus"].waitForExistence(timeout: 30), app.debugDescription)
        let local = app.buttons["workspace.start.local"]
        if local.waitForExistence(timeout: 3) { local.click() }
        return app
    }

    func test1WorkSurvivesRelaunch() throws {
        continueAfterFailure = false
        var app = launch()
        shot("mac-01-launched", app)
        app.descendants(matching: .any)["mac.sidebar.inbox"].firstMatch.click()
        let title = app.descendants(matching: .any)["inbox.quick.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        title.click(); title.typeText("Mac 验证同步改写")
        app.descendants(matching: .any)["inbox.quick.save"].firstMatch.click()
        XCTAssertTrue(text(app, "Mac 验证同步改写").waitForExistence(timeout: 10), app.debugDescription)
        shot("mac-02-work-added", app)
        app.terminate()
        app = launch()
        app.descendants(matching: .any)["mac.sidebar.inbox"].firstMatch.click()
        XCTAssertTrue(text(app, "Mac 验证同步改写").waitForExistence(timeout: 10), "Work survives relaunch")
        shot("mac-03-after-relaunch", app)
    }

    func test2ConnectFolder() throws {
        continueAfterFailure = false
        let folder = try XCTUnwrap(ProcessInfo.processInfo.environment["CUBIC_SYNC_FOLDER"], "Set CUBIC_SYNC_FOLDER")
        let app = launch()
        app.buttons["open-settings"].firstMatch.click()
        let status = app.descendants(matching: .any)["sync.status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription)
        reveal(app, status)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "仅本机")).firstMatch.exists
            || app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@", "仅本机")).firstMatch.exists, app.debugDescription)
        shot("mac-04-settings-local-only", app)

        let select = app.buttons["sync.file.select"]
        reveal(app, select)
        select.click()
        sleep(2)
        shot("mac-05-open-panel", app)
        // Go to the folder by path in the open panel, then choose it.
        app.typeKey("g", modifierFlags: [.command, .shift]); sleep(1)
        app.typeText(folder + "\n"); sleep(2)
        app.typeKey(.return, modifierFlags: []); sleep(2)
        let upload = app.windows.buttons["上传本机数据到此目录"].firstMatch
        XCTAssertTrue(upload.waitForExistence(timeout: 15), app.debugDescription)
        shot("mac-06-confirm-upload", app)
        upload.click()
        let synced = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND (label == %@ OR value == %@)", "sync.status", "已同步", "已同步")).firstMatch
        XCTAssertTrue(synced.waitForExistence(timeout: 20), app.debugDescription)
        shot("mac-07-connected", app)
    }
}
