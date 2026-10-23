import XCTest

/// Drives a fresh install through local saving, relaunch, settings and connecting a sync folder.
/// Run on a simulator without Cubic installed (`xcrun simctl uninstall <id> local.liwei.Cubic`).
/// The Files picker taps use iPhone 17-sized screen positions.
@MainActor final class SyncRewriteSmokeTests: XCTestCase {
    private func shot(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-tree"; tree.lifetime = .keepAlways; add(tree)
    }
    private func dismissStartCard(_ app: XCUIApplication) {
        let local = app.buttons["workspace.start.local"]
        if local.waitForExistence(timeout: 3) { local.tap() }
    }
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<12 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    func test1FreshInstallSavesWorkAcrossRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.buttons["workspace.start.local"].waitForExistence(timeout: 5), "Empty local workspace shows start options")
        shot("01-fresh-empty", app)
        dismissStartCard(app)

        app.buttons["收件箱"].tap()
        let title = app.descendants(matching: .any)["inbox.quick.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        title.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5) || title.value(forKey: "hasKeyboardFocus") as? Bool == true, app.debugDescription)
        title.typeText("验证同步改写")
        app.buttons["inbox.quick.save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["验证同步改写"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        shot("02-work-added", app)

        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["收件箱"].waitForExistence(timeout: 30))
        app.buttons["收件箱"].tap()
        XCTAssertTrue(app.staticTexts["验证同步改写"].firstMatch.waitForExistence(timeout: 10), "Work survives relaunch")
        shot("03-after-relaunch", app)
    }

    func test2SettingsShowLocalOnlyAndConnectFolder() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 30))
        dismissStartCard(app)
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10), app.debugDescription)
        let status = app.descendants(matching: .any)["sync.status"].firstMatch
        reveal(app, status)
        XCTAssertTrue(status.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "仅本机")).firstMatch.exists, app.debugDescription)
        shot("04-settings-local-only", app)

        let select = app.buttons["sync.file.select"]
        reveal(app, select)
        select.tap()
        sleep(3)
        shot("05-folder-picker", app)
    }

    func test3ConnectFolderUploadsCubicJSON() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 30))
        dismissStartCard(app)
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        let select = app.buttons["sync.file.select"]
        reveal(app, select)
        select.tap()
        // The document picker runs out of process; its rows are tapped by screen position (points).
        func tap(_ x: CGFloat, _ y: CGFloat) {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap(); sleep(2)
        }
        let browse = app.buttons["浏览"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 15), app.debugDescription)
        browse.tap(); sleep(2); browse.tap(); sleep(2)  // a second tap returns to the locations list
        shot("06-browse", app)
        tap(116, 318)  // 我的 iPhone
        shot("07-on-my-iphone", app)
        tap(71, 253)   // Cubic folder (the app's Documents)
        shot("08-cubic-folder", app)
        tap(353, 110)  // 打开
        let upload = app.buttons["上传本机数据到此目录"].firstMatch
        XCTAssertTrue(upload.waitForExistence(timeout: 15), app.debugDescription)
        shot("09-confirm-upload", app)
        upload.tap()
        let synced = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label == %@", "sync.status", "已同步")).firstMatch
        XCTAssertTrue(synced.waitForExistence(timeout: 20), app.debugDescription)
        reveal(app, app.buttons["sync.disconnect"])
        shot("10-connected", app)
    }
}
