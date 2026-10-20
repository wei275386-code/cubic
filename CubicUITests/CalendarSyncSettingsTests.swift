import XCTest
@preconcurrency import EventKit

/// Native device UI acceptance uses the debug-only QA workspace. The first
/// batch keeps settings unchanged; EventKit integration grants only expected
/// app/QA-runner access and creates its own unique, disposable QA calendar.
@MainActor final class CalendarSyncSettingsTests: XCTestCase {
    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"; tree.lifetime = .keepAlways
        add(tree)
    }

    private func launchQA() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CubicWorkCalendarQA", "-CubicWorkCalendarQAReset"]
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20))
        return app
    }

    private func requireCoordinatedICloudQA() throws {
        guard Bundle.main.object(forInfoDictionaryKey: "CubicNativeICloudQAEnabled") as? Bool == true else {
            throw XCTSkip("Real iCloud QA requires the prepared runner and an independent Mac observer/harness; see ui-qa.md")
        }
    }

    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<15 {
            if element.exists {
                let frame = element.frame
                if frame.minY > 110 && frame.maxY < app.frame.height - 35 { return }
                if frame.minY < 110 { app.swipeDown(); continue }
            }
            app.swipeUp()
        }
    }

    func testICloudSettingsUploadOn17Pro() throws {
        guard ProcessInfo.processInfo.environment["CUBIC_SETTINGS_SYNC_QA_PHASE"] == "upload",
              let folder = ProcessInfo.processInfo.environment["CUBIC_SETTINGS_SYNC_QA_FOLDER"], folder.hasPrefix("Cubic Settings QA ") else {
            throw XCTSkip("Dedicated real iCloud settings upload requires its QA folder")
        }
        let app = launchQA()
        app.buttons["open-settings"].tap()
        let zone = app.textFields["capacity.timeZone"]
        reveal(app, zone)
        if zone.value as? String != "Asia/Singapore" {
            zone.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            zone.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (zone.value as? String ?? "").count))
            zone.typeText("Asia/Singapore")
        }
        app.navigationBars["设置"].tap()
        let weekends = app.switches["capacity.weekends"]
        reveal(app, weekends)
        if weekends.value as? String != "1" { weekends.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        app.navigationBars["设置"].buttons["保存"].tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15))
        app.buttons["open-settings"].tap()
        let select = app.buttons["sync.file.select"]
        reveal(app, select); select.tap()
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
        let title = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons.matching(NSPredicate(format: "label BEGINSWITH %@", folder)).firstMatch
        // Files may hydrate a cloud-only folder on the first tap without entering it.
        for _ in 0..<3 {
            if title.exists { break }
            XCTAssertTrue(directory.isHittable, app.debugDescription)
            directory.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            if title.waitForExistence(timeout: 8) { break }
        }
        XCTAssertTrue(title.exists, app.debugDescription)
        app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons["打开"].tap()
        let create = app.buttons["创建同步目录并上传本机数据"]
        XCTAssertTrue(create.waitForExistence(timeout: 20)); create.tap()
        assertSettingsSyncSettled(app)
        capture("settings-17pro-upload", app: app)
        app.navigationBars["设置"].buttons["取消"].tap()
        app.terminate(); app.launchArguments = ["-CubicWorkCalendarQA"]; app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20)); app.buttons["open-settings"].tap()
        XCTAssertEqual(app.textFields["capacity.timeZone"].value as? String, "Asia/Singapore")
        XCTAssertEqual(app.switches["capacity.weekends"].value as? String, "1")
        capture("settings-17pro-upload-restarted", app: app)
    }

    func testICloudSettingsReceiveAndRestartOn17Pro() throws {
        guard ProcessInfo.processInfo.environment["CUBIC_SETTINGS_SYNC_QA_PHASE"] == "receive" else {
            throw XCTSkip("Run after the independent Mac observer publishes QA preferences")
        }
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-CubicWorkCalendarQA"]; app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20)); app.buttons["open-settings"].tap()
        let refresh = app.buttons["sync.refresh"]; reveal(app, refresh)
        if refresh.isEnabled { refresh.tap() }
        assertSettingsSyncSettled(app)
        // Reopen the draft to inspect the newly received model settings.
        app.navigationBars["设置"].buttons["取消"].tap()
        app.buttons["open-settings"].tap()
        assertMacSettings(app)
        capture("settings-17pro-received-mac", app: app)
        app.navigationBars["设置"].buttons["取消"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20)); app.buttons["open-settings"].tap()
        assertMacSettings(app)
        capture("settings-17pro-received-restarted", app: app)
        // A subsequent native save must keep received settings and upload just the changed group.
        let weekends = app.switches["capacity.weekends"]
        // SwiftUI removes rows above the viewport from the accessibility tree.
        for _ in 0..<8 where !weekends.exists { app.swipeDown() }
        reveal(app, weekends)
        weekends.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.navigationBars["设置"].buttons["保存"].tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15)); app.buttons["open-settings"].tap()
        reveal(app, refresh); assertSettingsSyncSettled(app)
        capture("settings-17pro-return-edit-uploaded", app: app)
        let disconnect = app.buttons["sync.disconnect"]
        reveal(app, disconnect); XCTAssertTrue(disconnect.isHittable); disconnect.tap()
        let local = NSPredicate { _, _ in app.staticTexts["sync.status"].firstMatch.label == "已保存在此设备" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: local, object: nil)], timeout: 15), .completed, app.debugDescription)
        capture("settings-17pro-disconnected-preserved", app: app)
        app.navigationBars["设置"].buttons["取消"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20)); app.buttons["open-settings"].tap()
        reveal(app, app.textFields["capacity.timeZone"])
        XCTAssertEqual(app.textFields["capacity.timeZone"].value as? String, "Asia/Tokyo")
        XCTAssertEqual(app.switches["capacity.weekends"].value as? String, "1")
        let reminders = app.switches["settings.remindersEnabled"]; reveal(app, reminders)
        XCTAssertEqual(reminders.value as? String, "1")
        reveal(app, refresh)
        XCTAssertEqual(app.staticTexts["sync.status"].firstMatch.label, "已保存在此设备")
        XCTAssertFalse(app.staticTexts["本机记录未能打开"].exists)
        capture("settings-17pro-disconnected-restarted", app: app)
    }

    private func assertMacSettings(_ app: XCUIApplication) {
        reveal(app, app.textFields["capacity.timeZone"])
        XCTAssertEqual(app.textFields["capacity.timeZone"].value as? String, "Asia/Tokyo", app.debugDescription)
        XCTAssertEqual(app.switches["capacity.weekends"].value as? String, "0")
        capture("settings-17pro-received-work-schedule", app: app)
        let day = app.buttons["capacity.dayOverride"].firstMatch
        reveal(app, day); day.tap()
        XCTAssertTrue(app.switches["capacity.dayUnavailable"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.switches["capacity.dayUnavailable"].value as? String, "1")
        capture("settings-17pro-received-day-override", app: app)
        app.navigationBars["单日工作时间"].buttons.element(boundBy: 0).tap()
        let calendar = app.switches["settings.calendarEnabled"]; reveal(app, calendar)
        XCTAssertEqual(calendar.value as? String, "1")
        let reminders = app.switches["settings.remindersEnabled"]; reveal(app, reminders)
        XCTAssertEqual(reminders.value as? String, "1")
        let waiting = app.switches["settings.reminders.waiting"]; reveal(app, waiting)
        XCTAssertEqual(waiting.value as? String, "0")
        let results = app.switches["settings.reminders.results"]; reveal(app, results)
        XCTAssertEqual(results.value as? String, "0")
    }
    func testReadOnlyOrdinarySettingsAfterUpgradeOn17Pro() throws {
        guard ProcessInfo.processInfo.environment["CUBIC_SETTINGS_SYNC_QA_PHASE"] == "ordinary" else {
            throw XCTSkip("Ordinary settings inspection is opt-in")
        }
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = []
        if ProcessInfo.processInfo.environment["CUBIC_SETTINGS_SYNC_QA_ATTACH"] == "1",
           app.state == .runningForeground || app.state == .runningBackground {
            app.activate()
            if app.navigationBars["设置"].exists { app.navigationBars["设置"].buttons["取消"].tap() }
        } else { app.launch() }
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 25)); app.buttons["open-settings"].tap()
        XCTAssertTrue(app.textFields["capacity.timeZone"].exists)
        capture("settings-17pro-ordinary-work-time", app: app)
        reveal(app, app.buttons["sync.refresh"])
        XCTAssertFalse(app.staticTexts["同步设置需要检查"].exists)
        XCTAssertTrue(app.staticTexts["Cubic"].exists, "Ordinary production binding must remain Cubic")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Cubic Settings QA ")).firstMatch.exists)
        // Refresh reads current provider facts and completes any one-time upgrade migration.
        let refresh = app.buttons["sync.refresh"]
        if refresh.isEnabled { refresh.tap() }
        assertSettingsSyncSettled(app, timeout: 300)
        capture("settings-17pro-ordinary-sync", app: app)
        app.navigationBars["设置"].buttons["取消"].tap()
    }
    private func assertSettingsSyncSettled(_ app: XCUIApplication, timeout: TimeInterval = 60) {
        let settled = NSPredicate { _, _ in
            app.staticTexts["sync.status"].firstMatch.label == "已同步"
            && app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "待上传 0 · 待完整下载 0 · 冲突 0")).firstMatch.exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: timeout), .completed, app.debugDescription)
    }

    func testDataSyncFolderPickerIsReachableAndCancellationPreservesLocalData() throws {
        let app = launchQA()
        app.buttons["open-settings"].tap()
        let select = app.buttons["sync.file.select"]
        reveal(app, select)
        XCTAssertTrue(select.isHittable, app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "仅本机")).firstMatch.exists)
        capture("data-sync-settings-local", app: app)
        select.tap()
        let pickerPresented = NSPredicate { _, _ in !select.isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: pickerPresented, object: nil)], timeout: 15), .completed, app.debugDescription)
        let cancel = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons["取消"].firstMatch
        if !cancel.isHittable {
            // A preceding folder test may leave Files on its restored browse path.
            app.tabBars["DOC.browsingModeTabBar"].buttons["最近项目"].tap()
        }
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        capture("native-folder-picker", app: app)
        cancel.tap()
        let pickerDismissed = NSPredicate { _, _ in select.isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: pickerDismissed, object: nil)], timeout: 15), .completed, app.debugDescription)
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sync.file.select"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "仅本机")).firstMatch.exists)
        capture("folder-picker-cancelled-local-preserved", app: app)
        app.navigationBars["设置"].buttons["取消"].tap()
        XCTAssertTrue(app.buttons["行动"].waitForExistence(timeout: 10))
    }

    func testAppleCalendarSetupIsReachableFromSettingsAndCalendar() throws {
        let app = launchQA()
        app.buttons["open-settings"].tap()
        let status = app.staticTexts["calendar.sync.status"].firstMatch
        reveal(app, status)
        XCTAssertTrue(status.exists && status.isHittable, app.debugDescription)
        XCTAssertFalse(app.buttons["calendar.sync.disable"].exists, "QA calendar binding must be disabled and isolated")
        capture("apple-calendar-settings-disabled", app: app)
        let permission = app.buttons["calendar.sync.permission"]
        if permission.exists {
            XCTAssertTrue(permission.isHittable)
        } else {
            let disclosure = app.buttons["选择专用日历并开启同步"].firstMatch
            XCTAssertTrue(disclosure.exists, app.debugDescription)
            disclosure.tap()
            capture("apple-calendar-source-and-binding-choices", app: app)
            if app.buttons["calendar.sync.create"].exists {
                XCTAssertFalse(app.buttons["calendar.sync.create"].isEnabled, "No calendar is created without an explicit source")
            }
        }
        app.navigationBars["设置"].buttons["取消"].tap()
        app.buttons["日历"].tap()
        let settings = app.descendants(matching: .any)["calendar.integration.settings"].firstMatch
        reveal(app, settings)
        XCTAssertTrue(settings.exists && settings.isHittable, app.debugDescription)
        capture("calendar-tab-integration-entry", app: app)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Apple Calendar 同步"].waitForExistence(timeout: 10), app.debugDescription)
        capture("calendar-tab-setup-navigation", app: app)
    }

    /// The directory is a unique, empty iCloud Drive QA location prepared on Mac.
    /// This test leaves its isolated binding intact for the second-device harness.
    func testNativeICloudDriveConnectAndRestart() throws {
        try requireCoordinatedICloudQA()
        let app = launchQA()
        app.buttons["open-settings"].tap()
        let select = app.buttons["sync.file.select"]
        reveal(app, select)
        XCTAssertTrue(select.isHittable)
        select.tap()
        let browse = app.tabBars["DOC.browsingModeTabBar"].buttons["浏览"]
        XCTAssertTrue(browse.waitForExistence(timeout: 15), app.debugDescription)
        browse.tap()
        // Files restores its last browsed location. Return to provider roots.
        let cloud = app.staticTexts.matching(NSPredicate(format: "label == 'iCloud Drive' OR label == 'iCloud云盘' OR label == 'iCloud 云盘'")).firstMatch
        for _ in 0..<8 {
            if cloud.exists { break }
            let back = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons["BackButton"]
            if back.waitForExistence(timeout: 3) { back.tap() } else { browse.tap() }
        }
        capture("native-icloud-drive-locations", app: app)
        XCTAssertTrue(cloud.waitForExistence(timeout: 15), app.debugDescription)
        cloud.tap()
        let directory = app.cells["Cubic Sync QA 20261007-0235, Folder"].firstMatch
        reveal(app, directory)
        XCTAssertTrue(directory.isHittable, app.debugDescription)
        directory.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let directoryTitle = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Cubic Sync QA 20261007-0235")).firstMatch
        XCTAssertTrue(directoryTitle.waitForExistence(timeout: 20), app.debugDescription)
        capture("native-icloud-drive-qa-directory", app: app)
        let open = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons["打开"]
        XCTAssertTrue(open.isEnabled, app.debugDescription)
        open.tap()
        let create = app.buttons["创建同步目录并上传本机数据"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Cubic Sync QA 20261007-0235")).firstMatch.exists, "Must confirm the exact QA directory before creating files: \(app.debugDescription)")
        capture("native-icloud-drive-explicit-create", app: app)
        create.tap()
        let settled = NSPredicate { _, _ in
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "待上传 0 · 待完整下载 0 · 冲突 0")).firstMatch.exists
                && app.buttons["sync.file.reauthorize"].exists
                && app.staticTexts["sync.status"].firstMatch.label == "已同步"
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 60), .completed, app.debugDescription)
        capture("native-icloud-drive-connected-uploaded", app: app)
        app.navigationBars["设置"].buttons["取消"].tap()
        app.terminate()
        app.launchArguments = ["-CubicWorkCalendarQA"]
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20))
        app.buttons["open-settings"].tap()
        reveal(app, app.buttons["sync.file.reauthorize"])
        XCTAssertTrue(app.buttons["sync.file.reauthorize"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Cubic Sync QA 20261007-0235")).firstMatch.exists)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 60), .completed, app.debugDescription)
        capture("native-icloud-drive-binding-after-restart", app: app)
        app.navigationBars["设置"].buttons["取消"].tap()
        print("QA-ICLOUD-FILE connected=Cubic Sync QA 20261007-0235 pending=0 restart=preserved")
    }

    /// Run after Mac's production Core harness publishes the unique QA rename.
    func testNativeICloudDriveMacRenameMiniEditAndRestart() throws {
        try requireCoordinatedICloudQA()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CubicWorkCalendarQA"]
        app.launch()
        XCTAssertTrue(app.buttons["行动"].waitForExistence(timeout: 20))
        app.buttons["行动"].tap()
        let work = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "QA Mac iCloud 20261007-0235、", "QA mini iCloud 20261007-0235QA Mac iCloud 20261007-0235、")).firstMatch
        let imported = NSPredicate { _, _ in work.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: imported, object: nil)], timeout: 60), .completed, app.debugDescription)
        reveal(app, work)
        capture("native-icloud-drive-mac-rename-received", app: app)
        work.tap()
        let edit = app.buttons["work.edit"]
        reveal(app, edit)
        XCTAssertTrue(edit.isHittable)
        edit.tap()
        let name = app.descendants(matching: .any)["editor.item.name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.press(forDuration: 1.2)
        let selectAll = app.menuItems["全选"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), app.debugDescription)
        selectAll.tap()
        name.typeText("QA mini iCloud 20261007-0235")
        capture("native-icloud-drive-mini-rename-editor", app: app)
        app.buttons["editor.item.save"].tap()
        XCTAssertTrue(app.staticTexts["QA mini iCloud 20261007-0235"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["行动"].waitForExistence(timeout: 20))
        app.buttons["行动"].tap()
        let miniWork = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "QA mini iCloud 20261007-0235、")).firstMatch
        reveal(app, miniWork)
        XCTAssertTrue(miniWork.exists, app.debugDescription)
        capture("native-icloud-drive-mini-rename-after-restart", app: app)
        app.buttons["open-settings"].tap()
        reveal(app, app.buttons["sync.file.reauthorize"])
        let settled = NSPredicate { _, _ in
            app.buttons["sync.file.reauthorize"].exists && app.staticTexts["sync.status"].firstMatch.label == "已同步"
                && app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "待上传 0 · 待完整下载 0 · 冲突 0")).firstMatch.exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 60), .completed, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Cubic Sync QA 20261007-0235"].exists, app.debugDescription)
        capture("native-icloud-drive-mini-edit-uploaded-after-restart", app: app)
        app.navigationBars["设置"].buttons["取消"].tap()
        print("QA-ICLOUD-FILE macRename=received miniRename=QA mini iCloud 20261007-0235 restart=preserved")
    }

    /// Read-only final check of the ordinary launch configuration.
    func testNormalWorkspaceRestoredWithoutQAArguments() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "QA 删除工作、")).firstMatch.exists)
        app.buttons["日历"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["calendar.project.qa-project"].exists, "Normal launch must not expose the isolated QA workspace")
        capture("normal-workspace-restored-without-qa-arguments", app: app)
        print("QA-NORMAL-RESTORE launchArguments=[] qaProjectAbsent=true")
    }

    /// Opt-in Pro acceptance of a fresh ordinary installation. Never resets data.
    func testProEmptyOrdinaryOnboardingAndRelaunch() throws {
        guard ProcessInfo.processInfo.environment["CUBIC_PRO_EMPTY_ONBOARDING_QA"] == "1" else {
            throw XCTSkip("Pro-only empty installation acceptance must be explicitly enabled")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20), app.debugDescription)
        let forbidden = ["A：完成报价表", "B：提交申请", "C：制作合同", "A · 完成报价表", "B · 提交申请", "C · 制作合同"]
        func assertNoSample() {
            for name in forbidden { XCTAssertFalse(app.staticTexts[name].exists, app.debugDescription) }
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "示例数据")).firstMatch.exists, app.debugDescription)
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "示例提供")).firstMatch.exists, app.debugDescription)
        }
        for tab in ["收件箱", "行动", "日历", "项目"] {
            app.buttons[tab].tap()
            assertNoSample()
            capture("pro-empty-" + tab, app: app)
        }
        app.buttons["open-settings"].tap()
        let status = app.descendants(matching: .any)["sync.status"].firstMatch
        reveal(app, status)
        XCTAssertTrue(status.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["仅本机"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["待上传 0 · 待完整下载 0 · 冲突 0"].exists, app.debugDescription)
        capture("pro-empty-settings-local-zero-pending", app: app)
        app.navigationBars["设置"].buttons["取消"].tap()
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20), app.debugDescription)
        assertNoSample()
        capture("pro-empty-ordinary-relaunch", app: app)
        print("QA-PRO-EMPTY launchArguments=[] allTabsNoSample=true localOnly=true pending=0 relaunchNoSample=true")
    }

    /// Creates a uniquely named real EventKit calendar. All external mutations
    /// are confined to that calendar; this is a single-device integration test.
    func testNativeEventKitUnlinkedAssociationAndDeletedEventReview() async throws {
        try requireCoordinatedICloudQA()
        try await verifyEventKitAssociationAndDeletedEventReview(coordinatedMacEdit: true)
    }

    /// Single-device SDK acceptance uses only its unique disposable calendar.
    func testNativeEventKitSingleDeviceAssociationAndDeletedEventReview() async throws {
        try await verifyEventKitAssociationAndDeletedEventReview(coordinatedMacEdit: false)
    }

    private func verifyEventKitAssociationAndDeletedEventReview(coordinatedMacEdit: Bool) async throws {
        let app = launchQA()
        // Swift throws must unwind fixture cleanup; assertions must not raise
        // an Objective-C control-flow exception across this async test.
        continueAfterFailure = true
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.buttons["open-settings"].tap()
        let permission = app.buttons["calendar.sync.permission"]
        reveal(app, app.staticTexts["calendar.sync.status"].firstMatch)
        if permission.exists {
            permission.tap()
            let alert = springboard.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 10))
            capture("native-calendar-permission", app: springboard)
            let allow = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] '完整访问' OR label CONTAINS[c] '完全访问' OR label CONTAINS[c] 'Full Access'")).firstMatch
            XCTAssertTrue(allow.exists, alert.debugDescription)
            allow.tap()
        }
        XCTAssertFalse(permission.waitForExistence(timeout: 2), "App must have calendar full access before the isolated integration test")

        guard Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil else {
            throw XCTSkip("Native UI runner lacks NSCalendarsFullAccessUsageDescription; cannot request EventKit access safely")
        }
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            let access = Task.detached {
                let permissionStore = EKEventStore()
                return try await permissionStore.requestFullAccessToEvents()
            }
            let alert = springboard.alerts.firstMatch
            if alert.waitForExistence(timeout: 10) {
                capture("native-qa-runner-calendar-permission", app: springboard)
                let allow = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] '完整访问' OR label CONTAINS[c] '完全访问' OR label CONTAINS[c] 'Full Access'")).firstMatch
                XCTAssertTrue(allow.exists, alert.debugDescription)
                allow.tap()
            }
            let granted = try await access.value
            if !granted {
                // A prior aborted prompt may leave this disposable test runner denied.
                // Change only this runner's expected Calendar test permission.
                let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
                settings.launch()
                let privacy = settings.staticTexts["隐私与安全性"].firstMatch
                reveal(settings, privacy)
                XCTAssertTrue(privacy.isHittable, settings.debugDescription)
                privacy.tap()
                let calendarPermission = settings.staticTexts["日历"].firstMatch
                reveal(settings, calendarPermission)
                XCTAssertTrue(calendarPermission.isHittable, settings.debugDescription)
                calendarPermission.tap()
                capture("native-calendar-privacy-list", app: settings)
                let runner = settings.staticTexts["CubicUITests-Runner"].firstMatch
                reveal(settings, runner)
                XCTAssertTrue(runner.isHittable, settings.debugDescription)
                runner.tap()
                capture("native-qa-runner-calendar-privacy", app: settings)
                let full = settings.staticTexts.matching(NSPredicate(format: "label == '完全访问' OR label == '完整访问' OR label == 'Full Access'")).firstMatch
                XCTAssertTrue(full.isHittable, settings.debugDescription)
                full.tap()
                let confirmingAccess = springboard.alerts.firstMatch
                if confirmingAccess.waitForExistence(timeout: 5) {
                    let confirm = confirmingAccess.buttons.matching(NSPredicate(format: "label CONTAINS[c] '完全访问' OR label CONTAINS[c] '完整访问' OR label CONTAINS[c] 'Full Access'")).firstMatch
                    XCTAssertTrue(confirm.exists, confirmingAccess.debugDescription)
                    confirm.tap()
                }
                capture("native-qa-runner-full-access-enabled", app: settings)
                app.activate()
            }
            XCTAssertEqual(EKEventStore.authorizationStatus(for: .event), .fullAccess)
        }
        // Build the fixture store after authorization. A store created before
        // the runner permission prompt can retain an empty source snapshot.
        let store = EKEventStore()
        store.refreshSourcesIfNecessary()
        // Clean only this suite's previously created fixture if a failed test
        // interruption prevented its defer from running.
        if let interruptedID = ProcessInfo.processInfo.environment["CUBIC_CALENDAR_QA_CLEANUP_ID"],
           let interruptedTitle = ProcessInfo.processInfo.environment["CUBIC_CALENDAR_QA_CLEANUP_TITLE"],
           interruptedTitle.hasPrefix("Cubic QA ") {
            if let previous = store.calendar(withIdentifier: interruptedID) {
                guard previous.title == interruptedTitle else {
                    throw NSError(domain: "NativeCalendarQA", code: 3, userInfo: [NSLocalizedDescriptionKey: "Interrupted fixture identity does not match; cleanup refused"])
                }
                try store.removeCalendar(previous, commit: true)
                store.reset()
            }
            XCTAssertNil(store.calendar(withIdentifier: interruptedID))
            print("QA-CALENDAR previousCleanup=\(interruptedID) verifiedAbsent=true")
        }
        if let previous = store.calendar(withIdentifier: "ACC3F8DA-18D5-45C5-8739-E98C69BD43BE"), previous.title == "Cubic QA 7D8255F4" {
            try store.removeCalendar(previous, commit: true)
            store.reset()
            XCTAssertNil(store.calendar(withIdentifier: "ACC3F8DA-18D5-45C5-8739-E98C69BD43BE"))
            print("QA-CALENDAR previousCleanup=ACC3F8DA-18D5-45C5-8739-E98C69BD43BE verifiedAbsent=true")
        }
        XCTAssertNil(store.calendar(withIdentifier: "ACC3F8DA-18D5-45C5-8739-E98C69BD43BE"))
        if let previous = store.calendar(withIdentifier: "F31F39B5-FFA5-4094-9852-6B6AE38C4F56"), previous.title == "Cubic QA AB2A9253" {
            try store.removeCalendar(previous, commit: true)
            store.reset()
        }
        XCTAssertNil(store.calendar(withIdentifier: "F31F39B5-FFA5-4094-9852-6B6AE38C4F56"))
        print("QA-CALENDAR previousCleanup=F31F39B5-FFA5-4094-9852-6B6AE38C4F56 verifiedAbsent=true")
        if let previous = store.calendar(withIdentifier: "E209BD08-5E47-4A57-8A8B-603275B5C923"), previous.title == "Cubic QA 663794C0" {
            try store.removeCalendar(previous, commit: true)
            store.reset()
        }
        XCTAssertNil(store.calendar(withIdentifier: "E209BD08-5E47-4A57-8A8B-603275B5C923"))
        print("QA-CALENDAR previousCleanup=E209BD08-5E47-4A57-8A8B-603275B5C923 verifiedAbsent=true")
        if let previous = store.calendar(withIdentifier: "58636C88-FDA1-447D-8D18-478DC447D4A3"), previous.title == "Cubic QA 39E6DE2C" {
            try store.removeCalendar(previous, commit: true)
            store.reset()
        }
        XCTAssertNil(store.calendar(withIdentifier: "58636C88-FDA1-447D-8D18-478DC447D4A3"))
        print("QA-CALENDAR previousCleanup=58636C88-FDA1-447D-8D18-478DC447D4A3 verifiedAbsent=true")
        let source = try XCTUnwrap(store.sources.first { $0.title.localizedCaseInsensitiveContains("iCloud") }
            ?? store.sources.first { $0.sourceType == .local }
            ?? store.calendars(for: .event).first { $0.allowsContentModifications }?.source)
        let sourceTitle = source.title
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Cubic QA " + String(UUID().uuidString.prefix(8))
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        let calendarID = calendar.calendarIdentifier
        let calendarTitle = calendar.title
        defer {
            app.terminate()
            if let ownCalendar = store.calendar(withIdentifier: calendarID) {
                do {
                    try store.removeCalendar(ownCalendar, commit: true)
                    store.reset()
                    XCTAssertNil(store.calendar(withIdentifier: calendarID), "Own QA calendar must be removed")
                    print("QA-CALENDAR cleanup=\(calendarID) verifiedAbsent=true")
                } catch { XCTFail("Own QA calendar cleanup failed: \(error)") }
            }
        }
        print("QA-CALENDAR created=\(calendarID) source=\(sourceTitle) title=\(calendarTitle)")
        let event = EKEvent(eventStore: store)
        event.title = "QA 未关联的单次安排"
        event.calendar = calendar
        event.startDate = Date().addingTimeInterval(20 * 60)
        event.endDate = event.startDate.addingTimeInterval(15 * 60)
        try store.save(event, span: .thisEvent, commit: true)
        let eventID = try XCTUnwrap(event.eventIdentifier)
        let fixtureStart = try XCTUnwrap(event.startDate)
        let fixtureEnd = try XCTUnwrap(event.endDate)
        print("QA-ICLOUD-OBSERVATION calendar=\(calendarTitle) event=\(event.title ?? "") start=\(event.startDate!) end=\(event.endDate!) source=\(sourceTitle)")
        if coordinatedMacEdit && sourceTitle.localizedCaseInsensitiveContains("iCloud") {
            // Keep the unique fixture alive briefly for the independent Mac observer.
            try await Task.sleep(for: .seconds(10))
        }
        app.terminate()
        app.launchArguments = ["-CubicWorkCalendarQA"]
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20))
        app.buttons["open-settings"].tap()
        reveal(app, app.staticTexts["calendar.sync.status"].firstMatch)
        let disclosure = app.buttons["选择专用日历并开启同步"].firstMatch
        XCTAssertTrue(disclosure.exists, app.debugDescription)
        disclosure.tap()
        let binding = app.buttons["calendar.sync.bind.\(calendarID)"].firstMatch
        reveal(app, binding)
        XCTAssertTrue(binding.exists && binding.isHittable, app.debugDescription)
        binding.tap()
        // Binding takes effect immediately. Reopen the Form with the calendar
        // catalog collapsed, so its virtualized rows cannot hide the review
        // entry above the long catalog from the forward-only reveal helper.
        app.navigationBars["设置"].buttons["取消"].tap()
        app.buttons["open-settings"].tap()
        reveal(app, app.staticTexts["calendar.sync.status"].firstMatch)
        let review = app.buttons["calendar.sync.review"]
        reveal(app, review)
        guard review.waitForExistence(timeout: 10) && review.isHittable else {
            throw NSError(domain: "NativeCalendarQA", code: 4, userInfo: [NSLocalizedDescriptionKey: app.debugDescription])
        }
        capture("native-qa-calendar-bound", app: app)
        review.tap()
        let unlinked = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "QA 未关联的单次安排")).firstMatch
        guard unlinked.waitForExistence(timeout: 10) && unlinked.isHittable else {
            throw NSError(domain: "NativeICloudQA", code: 1, userInfo: [NSLocalizedDescriptionKey: app.debugDescription])
        }
        unlinked.tap()
        capture("native-unlinked-event-expanded", app: app)
        // Exact visible labels work across the native Picker accessibility types.
        let itemPicker = app.buttons["关联到已有工作"].firstMatch
        reveal(app, itemPicker)
        XCTAssertTrue(itemPicker.isHittable, app.debugDescription)
        itemPicker.tap()
        capture("native-unlinked-existing-work-choices", app: app)
        let choices = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "QA 删除工作"))
        let optionVisible = NSPredicate { _, _ in choices.allElementsBoundByIndex.contains { $0.isHittable } }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: optionVisible, object: nil)], timeout: 5)
        let item = try XCTUnwrap(choices.allElementsBoundByIndex.first { $0.isHittable }, app.debugDescription)
        item.tap()
        let associate = app.buttons["关联并创建 Cubic 时间块"].firstMatch
        XCTAssertTrue(associate.isEnabled)
        associate.tap()
        let associated = NSPredicate { _, _ in
            store.reset()
            return store.event(withIdentifier: eventID)?.url?.scheme == "cubic"
        }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: associated, object: nil)], timeout: 15)
        let linked = try XCTUnwrap(store.event(withIdentifier: eventID))
        let blockID = try XCTUnwrap(linked.url?.lastPathComponent)
        var expectedRestoredStart = try XCTUnwrap(linked.startDate)
        var expectedRestoredEnd = try XCTUnwrap(linked.endDate)
        let readOwnLinkedEvent = { () -> EKEvent? in
            guard let ownCalendar = store.calendar(withIdentifier: calendarID) else { return nil }
            let nearby = store.events(matching: store.predicateForEvents(withStart: fixtureStart.addingTimeInterval(-10 * 60), end: fixtureEnd.addingTimeInterval(10 * 60), calendars: [ownCalendar]))
            // EventKit identifiers may change after a calendar sync. The own
            // calendar and Cubic marker remain the unique test identity.
            return nearby.first { $0.url?.scheme == "cubic" && $0.url?.lastPathComponent == blockID }
        }
        capture("native-unlinked-associated", app: app)

        if coordinatedMacEdit && sourceTitle.localizedCaseInsensitiveContains("iCloud") {
            let beforeMacStart = expectedRestoredStart
            let beforeMacEnd = expectedRestoredEnd
            print("QA-MAC-EDIT-WINDOW calendar=\(calendarTitle) event=\(linked.title ?? "") blockID=\(blockID) start=\(beforeMacStart) end=\(beforeMacEnd) currentUTC=\(Date()) expectedStartDelta=120 expectedEndDelta=180")
            // iCloud propagation is asynchronous. Do not delete the fixture
            // until the independent Mac change is actually visible in mini.
            let macEditReceived = NSPredicate { _, _ in
                store.reset()
                guard let changed = readOwnLinkedEvent() else { return false }
                return abs(changed.startDate.timeIntervalSince(beforeMacStart) - 120) < 60
                    && abs(changed.endDate.timeIntervalSince(beforeMacEnd) - 180) < 60
            }
            let received = await XCTWaiter.fulfillment(of: [XCTNSPredicateExpectation(predicate: macEditReceived, object: nil)], timeout: 480)
            guard received == .completed else {
                store.reset()
                if let observed = readOwnLinkedEvent() {
                    print("QA-MAC-EDIT-TIMEOUT ownCalendar=\(calendarTitle) eventID=\(observed.eventIdentifier ?? "") start=\(observed.startDate!) end=\(observed.endDate!) marker=\(observed.url!.absoluteString)")
                } else { print("QA-MAC-EDIT-TIMEOUT ownCalendar=\(calendarTitle) markerEventMissing=true") }
                throw NSError(domain: "NativeICloudQA", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mac Calendar edit did not propagate to mini within 480 seconds"])
            }
            store.reset()
            let remotelyEdited = try XCTUnwrap(readOwnLinkedEvent())
            XCTAssertEqual(remotelyEdited.startDate.timeIntervalSince(beforeMacStart), 120, accuracy: 59)
            XCTAssertEqual(remotelyEdited.endDate.timeIntervalSince(beforeMacEnd), 180, accuracy: 59)
            expectedRestoredStart = remotelyEdited.startDate
            expectedRestoredEnd = remotelyEdited.endDate
            app.terminate(); app.launch()
            XCTAssertTrue(app.buttons["日历"].waitForExistence(timeout: 20))
            app.buttons["日历"].tap()
            let block = app.buttons["calendar.block.\(blockID)"]
            reveal(app, block)
            XCTAssertTrue(block.exists, app.debugDescription)
            capture("native-mac-calendar-edit-received", app: app)
            XCTAssertFalse(app.buttons["calendar.integration.review"].exists, "Valid Mac resize should import without divergence")
            print("QA-MAC-EDIT-RECEIVED block=\(blockID) start=\(remotelyEdited.startDate!) end=\(remotelyEdited.endDate!) ui=\(block.label)")
        }

        store.reset()
        try store.remove(try XCTUnwrap(readOwnLinkedEvent()), span: .thisEvent, commit: true)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["日历"].waitForExistence(timeout: 20))
        app.buttons["日历"].tap()
        let calendarReview = app.descendants(matching: .any)["calendar.integration.review"].firstMatch
        reveal(app, calendarReview)
        XCTAssertTrue(calendarReview.waitForExistence(timeout: 15), app.debugDescription)
        calendarReview.tap()
        let restore = app.buttons["calendar.divergence.restore.\(blockID)"]
        reveal(app, restore)
        XCTAssertTrue(restore.exists && restore.isHittable, app.debugDescription)
        XCTAssertFalse(app.buttons["calendar.divergence.accept.\(blockID)"].isEnabled)
        XCTAssertTrue(app.buttons["calendar.divergence.cancel.\(blockID)"].exists)
        capture("native-deleted-event-divergence", app: app)
        restore.tap()
        let expectedStart = expectedRestoredStart
        let expectedEnd = expectedRestoredEnd
        let restored = NSPredicate { _, _ in
            store.reset()
            let freshCalendar = store.calendar(withIdentifier: calendarID)
            let events = store.events(matching: store.predicateForEvents(withStart: fixtureStart.addingTimeInterval(-60), end: fixtureEnd.addingTimeInterval(10 * 60), calendars: freshCalendar.map { [$0] } ?? []))
            return events.contains { $0.url?.absoluteString.contains(blockID) == true
                && abs($0.startDate.timeIntervalSince(expectedStart)) < 1
                && abs($0.endDate.timeIntervalSince(expectedEnd)) < 1 }
        }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: restored, object: nil)], timeout: 15)
        capture("native-deleted-event-restored", app: app)
        print("QA-CALENDAR restoredBlock=\(blockID) expectedStart=\(expectedStart) expectedEnd=\(expectedEnd) exactTimesVerified=true")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20))
        app.buttons["open-settings"].tap()
        let disable = app.buttons["calendar.sync.disable"]
        reveal(app, disable)
        XCTAssertTrue(disable.isHittable)
        disable.tap()
        let confirmDisable = app.buttons["关闭同步"].firstMatch
        XCTAssertTrue(confirmDisable.waitForExistence(timeout: 5))
        confirmDisable.tap()
        print("QA-CALENDAR cleanup=\(calendarID)")
    }
}
