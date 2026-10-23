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
        capture("pro-empty-settings-local", app: app)
        app.navigationBars["设置"].buttons["取消"].tap()
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20), app.debugDescription)
        assertNoSample()
        capture("pro-empty-ordinary-relaunch", app: app)
        print("QA-PRO-EMPTY launchArguments=[] allTabsNoSample=true localOnly=true relaunchNoSample=true")
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
