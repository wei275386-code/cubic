import XCTest

/// Opt-in, native iPhone 17 Pro acceptance against the existing isolated Mac QA root.
/// It joins remote data without uploading the phone's previous QA workspace.
@MainActor final class MacCompanionSyncTests: XCTestCase {
    private let folder = "Cubic Native Mac QA 20261007-1905"
    private let macName = "Mac QA Remote Only"
    private let phoneName = "Mac QA 17Pro Round Trip 20261007-1905"

    func testMacTo17ProEditRestartAndUpload() throws {
        guard ProcessInfo.processInfo.environment["CUBIC_MAC_COMPANION_QA"] == "1" else {
            throw XCTSkip("Requires the coordinated existing native Mac QA workspace and iPhone 17 Pro")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CubicWorkCalendarQA"]
        app.launch()
        defer {
            app.terminate()
            app.launchArguments = []
            app.launch()
            capture("17pro-ordinary-workspace-restored", app)
        }
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20))
        app.buttons["open-settings"].tap()
        let select = app.buttons["sync.file.select"]
        reveal(app, select)
        if !app.staticTexts[folder].exists {
            select.tap()
            let browse = app.tabBars["DOC.browsingModeTabBar"].buttons["浏览"]
            XCTAssertTrue(browse.waitForExistence(timeout: 15)); browse.tap()
            let cloud = app.staticTexts.matching(NSPredicate(format: "label == 'iCloud Drive' OR label == 'iCloud云盘' OR label == 'iCloud 云盘'")).firstMatch
            for _ in 0..<8 where !cloud.exists {
                let back = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons["BackButton"]
                if back.waitForExistence(timeout: 3) { back.tap() } else { browse.tap() }
            }
            XCTAssertTrue(cloud.waitForExistence(timeout: 15)); cloud.tap()
            let directory = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", folder + ",")).firstMatch
            reveal(app, directory)
            XCTAssertTrue(directory.isHittable, app.debugDescription)
            let navigation = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
            let directoryTitle = navigation.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", folder)).firstMatch
            capture("17pro-exact-qa-folder-before-open", app)
            // A cloud-only folder can hydrate on its first tap while Files stays at the parent.
            for _ in 0..<3 {
                if directoryTitle.exists { break }
                XCTAssertTrue(directory.isHittable, app.debugDescription)
                directory.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
                if directoryTitle.waitForExistence(timeout: 8) { break }
            }
            XCTAssertTrue(directoryTitle.exists, app.debugDescription)
            capture("17pro-exact-mac-qa-folder", app)
            navigation.buttons["打开"].tap()
            let join = app.buttons["连接远端数据，保留本机旧数据"]
            XCTAssertTrue(join.waitForExistence(timeout: 20), "Must join existing remote; never create or merge a second bootstrap")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", folder)).firstMatch.exists)
            join.tap()
        }
        assertSettled(app)
        capture("17pro-joined-mac-workspace", app)
        app.navigationBars["设置"].buttons["取消"].tap()
        app.buttons["行动"].tap()
        let work = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", macName + "、")).firstMatch
        reveal(app, work)
        XCTAssertTrue(work.waitForExistence(timeout: 10), app.debugDescription)
        capture("17pro-received-native-mac-item", app)
        work.tap()
        let edit = app.buttons["work.edit"]
        reveal(app, edit); edit.tap()
        let name = app.descendants(matching: .any)["editor.item.name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap(); name.press(forDuration: 1.2)
        let selectAll = app.menuItems["全选"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), app.debugDescription)
        selectAll.tap(); name.typeText(phoneName)
        capture("17pro-native-edit", app)
        app.buttons["editor.item.save"].tap()
        XCTAssertTrue(app.staticTexts[phoneName].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["行动"].waitForExistence(timeout: 20)); app.buttons["行动"].tap()
        let renamed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", phoneName + "、")).firstMatch
        reveal(app, renamed)
        XCTAssertTrue(renamed.exists, app.debugDescription)
        capture("17pro-edit-after-restart", app)
        app.buttons["open-settings"].tap()
        reveal(app, app.buttons["sync.refresh"])
        if app.buttons["sync.refresh"].isEnabled { app.buttons["sync.refresh"].tap() }
        assertSettled(app)
        XCTAssertTrue(app.staticTexts[folder].exists)
        capture("17pro-bookmark-and-upload-after-restart", app)
        app.navigationBars["设置"].buttons["取消"].tap()
        print("MAC-COMPANION-QA received=\(macName) phoneEdit=\(phoneName) restart=preserved folder=\(folder)")
    }

    func testOrdinaryLaunchRestoresProductionWorkspace() throws {
        guard ProcessInfo.processInfo.environment["CUBIC_MAC_COMPANION_QA"] == "1" else {
            throw XCTSkip("Only the coordinated iPhone 17 Pro companion acceptance may run this check")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20), "Ordinary workspace must finish boot")
        capture("17pro-ordinary-workspace-ready", app)
        app.buttons["open-settings"].tap()
        reveal(app, app.buttons["sync.file.select"])
        XCTAssertFalse(app.staticTexts[folder].exists, "QA directory binding must stay out of production defaults")
        capture("17pro-production-sync-isolated", app)
        app.navigationBars["设置"].buttons["取消"].tap()
        capture("17pro-ordinary-workspace-final", app)
    }

    private func assertSettled(_ app: XCUIApplication) {
        let predicate = NSPredicate { _, _ in
            app.staticTexts["sync.status"].firstMatch.label == "已同步" &&
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "待上传 0 · 待完整下载 0 · 冲突 0")).firstMatch.exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 60), .completed, app.debugDescription)
    }

    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<15 {
            if element.exists, element.frame.minY > 110, element.frame.maxY < app.frame.height - 35 { return }
            if element.exists, element.frame.minY < 110 { app.swipeDown() } else { app.swipeUp() }
        }
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = name; screen.lifetime = .keepAlways; add(screen)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
}
