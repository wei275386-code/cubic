import XCTest

/// Independent physical-device acceptance. QA SQLite and sync identity only.
@MainActor final class ProjectTemplateUITests: XCTestCase {
    private let app = XCUIApplication()

    // Physical acceptance can reset isolated QA data or resume a stored checkpoint.
    // Select exactly one method in the test runner environment; ordinary suites skip it.
    private func requirePhysicalQA(_ function: String) throws {
        let method = function.replacingOccurrences(of: "()", with: "")
        guard ProcessInfo.processInfo.environment["CUBIC_PROJECT_TEMPLATE_QA_TEST"] == method else {
            throw XCTSkip("Physical template QA is opt-in. Set CUBIC_PROJECT_TEMPLATE_QA_TEST to the selected method and use -only-testing.")
        }
    }
    func testTemplateLifecycleOnPhysicalMini() throws {
        try requirePhysicalQA(#function)
        continueAfterFailure = false
        defer {
            capture("final-state")
            app.terminate(); app.launchArguments = []; app.launch()
        }
        app.launchArguments = ["-CubicWorkCalendarQA", "-CubicWorkCalendarQAReset"]
        app.launch()
        projectTab()
        tap(app.buttons["projects.project.qa-project"])
        let duration = app.textFields["project.structure.item.duration.qa-drag"]
        reveal(duration)
        XCTAssertEqual(duration.value as? String, "45")
        replaceText(duration, "75")
        commitKeyboard()
        tap(app.buttons["project.operations"])
        tap(app.buttons["project.saveTemplate"])
        XCTAssertTrue(app.textFields["template.editor.name"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["template.editor.name"].value as? String, "QA 工作删除与日历")
        capture("01-save-title")
        assertPreview()
        capture("02-save-preview")
        // Cancel does not save a template.
        tap(app.buttons["template.editor.cancel"])
        projectTab()
        tap(app.buttons["projects.templates"])
        XCTAssertTrue(app.otherElements["templates.empty"].exists || app.staticTexts["还没有项目模板"].exists)
        back("项目模板")
        tap(app.buttons["projects.project.qa-project"])
        tap(app.buttons["project.operations"]); tap(app.buttons["project.saveTemplate"])
        tap(app.buttons["template.editor.save"])
        projectTab(); tap(app.buttons["projects.templates"])
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "templates.template.")).firstMatch
        tap(row)
        capture("03-template-detail")
        tap(app.buttons["template.detail.create"])
        let enabled = app.switches["template.create.deadline.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(enabled.frame.height, 44)
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertFalse(app.buttons["template.create.save"].isEnabled)
        capture("04-deadline-disabled")
        tap(app.buttons["template.create.cancel"])
        projectTab()
        XCTAssertEqual(projectRows().count, 1, "Cancelled create draft must not append a project")
        tap(app.buttons["projects.templates"]); tap(row)
        tap(app.buttons["template.detail.create"])
        XCTAssertTrue(app.datePickers["template.create.deadline.date"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields.count, 0, "Content/name/duration must be read-only; deadline is the only input")
        capture("05-create-cutoff")
        tap(app.datePickers["template.create.deadline.date"])
        capture("05a-cutoff-date-picker")
        let newDay = app.buttons["10月20日 星期二"].firstMatch
        XCTAssertTrue(newDay.waitForExistence(timeout: 5), "Calendar day selector: \(app.debugDescription)")
        newDay.tap()
        // Dismiss compact calendar using the create navigation title.
        app.buttons["PopoverDismissRegion"].coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.20)).tap()
        capture("05b-cutoff-edited")
        assertPreview(); capture("06-create-preview")
        tap(app.buttons["template.create.save"])
        XCTAssertTrue(app.navigationBars["项目详情"].waitForExistence(timeout: 15))
        let firstWorkIDs = try assertCreated()
        let firstName = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "project.structure.item.name.", "QA 拖拽时间块")).firstMatch
        reveal(firstName)
        let firstID = firstName.identifier.replacingOccurrences(of: "project.structure.item.name.", with: "")
        capture("07-created-structure")
        tap(app.buttons["project.operations"]); tap(app.buttons["编辑项目属性"])
        let retainedDate = app.datePickers["editor.project.deadline.date"]
        reveal(retainedDate)
        XCTAssertTrue(retainedDate.debugDescription.contains("20日"), "Changed cutoff must persist: \(retainedDate.debugDescription)")
        capture("07a-created-cutoff")
        tap(app.buttons["editor.project.cancel"])
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "未开工")).count, 3)
        capture("07b-created-pending-work")
        // Rename only changes lookup title; relaunch retains snapshot.
        projectTab()
        let firstProjectID = (0..<projectRows().count).map { projectRows().element(boundBy: $0).identifier }.first { $0 != "projects.project.qa-project" }!
        tap(app.buttons["projects.templates"]); tap(row)
        tap(app.buttons["template.detail.operations"]); tap(app.buttons["template.detail.rename"])
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        replaceText(name, "QA 模板重命名")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["QA 模板重命名"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["template.preview.project"].label, "QA 工作删除与日历")
        capture("08-renamed-template")
        app.terminate(); app.launchArguments = ["-CubicWorkCalendarQA"]; app.launch()
        projectTab(); XCTAssertEqual(projectRows().count, 2)
        tap(app.buttons["projects.templates"]); tap(row)
        XCTAssertEqual(app.staticTexts["template.detail.title"].label, "QA 模板重命名")
        assertPreview(); capture("09-persisted-snapshot")
        tap(app.buttons["template.detail.create"]); tap(app.buttons["template.create.save"])
        XCTAssertTrue(app.navigationBars["项目详情"].waitForExistence(timeout: 15))
        let secondWorkIDs = try assertCreated()
        XCTAssertTrue(firstWorkIDs.isDisjoint(with: secondWorkIDs), "Instances must use different IDs")
        // Editing the second instance leaves the saved template and first instance untouched.
        let secondDuration = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "project.structure.item.duration.", "75")).firstMatch
        replaceText(secondDuration, "90")
        commitKeyboard()
        projectTab(); XCTAssertEqual(projectRows().count, 3)
        tap(app.buttons["projects.templates"]); tap(row)
        assertPreview()
        tap(app.buttons["template.detail.operations"]); tap(app.buttons["template.detail.delete"])
        capture("10-delete-confirmation")
        tap(app.buttons["template.delete.confirm"])
        XCTAssertTrue(app.staticTexts["还没有项目模板"].waitForExistence(timeout: 10))
        capture("11-deleted-list")
        projectTab(); XCTAssertEqual(projectRows().count, 3)
        capture("12-projects-survive-delete")
        // Find and verify the first instance's 75-minute work after second edit and template deletion.
        tap(app.buttons[firstProjectID])
        let target = app.textFields["project.structure.item.duration.\(firstID)"]
        reveal(target); XCTAssertEqual(target.value as? String, "75")
        capture("13-first-instance-still-independent")
    }
    func testTemplateAcceptanceCandidatesAndAnchorOnPhysicalMini() throws {
        try requirePhysicalQA(#function)
        continueAfterFailure = false
        app.launchArguments = ["-CubicWorkCalendarQA", "-CubicWorkCalendarQAReset"]; app.launch()
        projectTab(); tap(app.buttons["projects.waiting"]); tap(app.buttons["waiting.new"])
        fill(app.textFields["editor.blocker.name"], "QA 审批等待")
        fill(app.textFields["editor.blocker.condition"], "收到签字")
        fill(app.textFields["editor.blocker.duration"], "60")
        tap(app.buttons["editor.blocker.save"])
        projectTab(); tap(app.buttons["projects.project.qa-project"])
        tap(app.buttons["project.structure.node.info.qa-node"])
        let acceptance = app.buttons["project.structure.node.acceptance.qa-node"]
        XCTAssertTrue(acceptance.waitForExistence(timeout: 5))
        acceptance.tap()
        let addAcceptance = app.buttons["添加验收条件"].firstMatch
        XCTAssertTrue(addAcceptance.waitForExistence(timeout: 5))
        addAcceptance.tap()
        fill(app.textFields["editor.acceptance.name"], "QA 质量通过")
        let option = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "editor.acceptance.blocker.", "QA 审批等待")).firstMatch
        reveal(option); option.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        tap(app.buttons["editor.acceptance.save"])
        // Make source project deadline absent, and give a member its own deadline.
        tap(app.buttons["project.operations"]); tap(app.buttons["编辑项目属性"])
        let projectDue = app.switches["editor.project.deadline.enabled"]
        reveal(projectDue); projectDue.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        tap(app.buttons["editor.project.save"])
        tap(app.buttons["project.structure.item.info.qa-drag"])
        let workDue = app.switches["project.structure.item.deadline.qa-drag.enabled"]
        revealPopover(workDue)
        workDue.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let infoDone = app.buttons["project.structure.item.info.done.qa-drag"]
        XCTAssertTrue(infoDone.waitForExistence(timeout: 5))
        infoDone.tap()
        tap(app.buttons["project.operations"]); tap(app.buttons["project.saveTemplate"])
        XCTAssertFalse(app.buttons["template.editor.save"].isEnabled)
        reveal(app.switches["template.editor.anchor.enabled"])
        capture("A01-anchor-required")
        let anchor = app.switches["template.editor.anchor.enabled"]
        anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        reveal(app.staticTexts["template.preview.summary"])
        let candidates = app.staticTexts["返工可能涉及的等待：QA 审批等待"]
        reveal(candidates); XCTAssertTrue(candidates.exists)
        reveal(app.staticTexts["等待时长：1 小时"])
        capture("A02-static-candidates-and-waiting")
        tap(app.buttons["template.editor.save"])
        // Template-only anchor must not alter source project deadline.
        tap(app.buttons["project.operations"]); tap(app.buttons["编辑项目属性"])
        XCTAssertEqual(app.switches["editor.project.deadline.enabled"].value as? String, "0")
        tap(app.buttons["editor.project.cancel"])
        projectTab(); tap(app.buttons["projects.templates"])
        tap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "templates.template.")).firstMatch)
        reveal(candidates); capture("A03-saved-candidate-preview")
        tap(app.buttons["template.detail.create"])
        reveal(candidates); capture("A04-create-candidate-preview")
        tap(app.buttons["template.create.save"])
        XCTAssertTrue(app.navigationBars["项目详情"].waitForExistence(timeout: 15))
        let node = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "project.structure.node.name.", "QA 交付")).firstMatch
        reveal(node)
        let nodeID = node.identifier.replacingOccurrences(of: "project.structure.node.name.", with: "")
        tap(app.buttons["project.structure.node.info.\(nodeID)"])
        let createdAcceptance = app.buttons["project.structure.node.acceptance.\(nodeID)"]
        XCTAssertTrue(createdAcceptance.waitForExistence(timeout: 5))
        createdAcceptance.tap()
        let editAcceptance = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "acceptance.edit.")).firstMatch
        XCTAssertTrue(editAcceptance.waitForExistence(timeout: 5))
        editAcceptance.tap()
        XCTAssertEqual(app.textFields["editor.acceptance.name"].value as? String, "QA 质量通过")
        // Original and copied blockers have the same name. Exactly one new identity must be selected.
        let switches = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "editor.acceptance.blocker.", "QA 审批等待"))
        XCTAssertEqual(switches.count, 2)
        let selected = (0..<switches.count).filter { switches.element(boundBy: $0).value as? String == "1" }
        XCTAssertEqual(selected.count, 1)
        capture("A05-restored-candidate-selection")
        tap(app.buttons["editor.acceptance.cancel"])
    }

    func testTemplateExternalRelationshipBlocksOnPhysicalMini() throws {
        try requirePhysicalQA(#function)
        continueAfterFailure = false
        app.launchArguments = ["-CubicWorkCalendarQA", "-CubicWorkCalendarQAReset"]; app.launch()
        projectTab(); tap(app.buttons["projects.create"])
        fill(app.textFields["editor.project.name"], "QA 外部项目")
        tap(app.buttons["editor.project.save"])
        XCTAssertTrue(app.navigationBars["项目详情"].waitForExistence(timeout: 15))
        tap(app.buttons["project.structure.addDirectWork"])
        fill(app.textFields["editor.item.name"], "QA 外部工作")
        tap(app.buttons["editor.item.save"])
        projectTab(); tap(app.buttons["projects.project.qa-project"])
        tap(app.buttons["project.structure.item.predecessors.qa-drag"])
        capture("E00-expanded-dependency-picker")
        let search = app.textFields["project.structure.predecessors.search.qa-drag"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("外部工作")
        let choice = app.buttons["QA 外部工作"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        if !choice.isHittable, app.buttons["project.structure.keyboard.done"].exists {
            app.buttons["project.structure.keyboard.done"].tap()
        }
        XCTAssertTrue(choice.isHittable)
        choice.tap()
        let predecessorsDone = app.buttons["project.structure.predecessors.done.qa-drag"]
        XCTAssertTrue(predecessorsDone.waitForExistence(timeout: 5))
        predecessorsDone.tap()
        tap(app.buttons["project.operations"]); tap(app.buttons["project.saveTemplate"])
        let issue = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "前置关系涉及模板外的内容：QA 外部工作")).firstMatch
        reveal(issue); XCTAssertTrue(issue.exists)
        XCTAssertFalse(app.buttons["template.editor.save"].isEnabled)
        capture("E01-external-relationship-blocked")
        tap(app.buttons["template.editor.cancel"])
        projectTab(); tap(app.buttons["projects.templates"])
        XCTAssertTrue(app.staticTexts["还没有项目模板"].exists)
    }
    private func replaceText(_ field: XCUIElement, _ text: String) {
        reveal(field)
        let length = (field.value as? String ?? "").utf16.count
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length + 2) + text)
        XCTAssertEqual(field.value as? String, text, "Replacement must finish before saving fixture")
    }
    private func fill(_ field: XCUIElement, _ text: String) {
        reveal(field); field.tap(); field.typeText(text)
    }

    private func assertPreview() {
        // A sheet leaves the underlying template detail in AX. Scope to the foreground Form/List.
        let content = app.collectionViews.allElementsBoundByIndex.last ?? app
        let summary = content.staticTexts["template.preview.summary"]
        reveal(summary); XCTAssertEqual(summary.label, "1 个节点 · 3 项工作 · 2 条前置关系")
        XCTAssertEqual(content.staticTexts["template.preview.project"].label, "QA 工作删除与日历")
        XCTAssertEqual(content.staticTexts["template.preview.duration"].label, "总耗时：2 小时 15 分")
        let changed = content.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "耗时：1 小时 15 分")).firstMatch
        reveal(changed); XCTAssertTrue(changed.exists)
        let predecessor = content.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "前置：QA 删除工作")).firstMatch
        reveal(predecessor); XCTAssertTrue(predecessor.exists)
        XCTAssertFalse(content.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "时间估计")).firstMatch.exists)
    }
    private func assertCreated() throws -> Set<String> {
        let node = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "project.structure.node.name.", "QA 交付")).firstMatch
        reveal(node); XCTAssertTrue(node.exists)
        var ids = Set<String>()
        for (name, minutes) in [("QA 拖拽时间块", "75"), ("QA 删除工作", "30"), ("QA 保留工作", "30")] {
            let work = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "project.structure.item.name.", name)).firstMatch
            reveal(work); XCTAssertTrue(work.exists)
            let id = work.identifier.replacingOccurrences(of: "project.structure.item.name.", with: "")
            ids.insert(id)
            let duration = app.textFields["project.structure.item.duration.\(id)"]
            reveal(duration); XCTAssertEqual(duration.value as? String, minutes)
            XCTAssertFalse(["qa-drag", "qa-delete", "qa-keep"].contains(id))
        }
        XCTAssertEqual(ids.count, 3)
        return ids
    }
    private func projectRows() -> XCUIElementQuery { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "projects.project.")) }
    private func projectTab() {
        let tab = app.tabBars.buttons["项目"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10)); tab.tap()
        // Tab selection preserves its NavigationStack. Pop to root if needed.
        for _ in 0..<4 {
            if app.navigationBars["项目"].exists { return }
            let bar = app.navigationBars.firstMatch
            if bar.buttons.count > 0 { bar.buttons.element(boundBy: 0).tap() }
        }
        XCTAssertTrue(app.navigationBars["项目"].exists)
    }
    private func back(_ title: String) { app.navigationBars[title].buttons.element(boundBy: 0).tap() }
    private func tap(_ element: XCUIElement) { reveal(element); XCTAssertTrue(element.waitForExistence(timeout: 10)); XCTAssertTrue(element.isHittable); element.tap() }
    /// 耗时用数字键盘，回车不会提交。工具栏“完成”或把焦点移开都会保存一次。
    private func commitKeyboard() {
        let done = app.buttons["project.structure.keyboard.done"]
        if done.waitForExistence(timeout: 3) {
            done.tap()
            return
        }
        let node = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "project.structure.node.name.")).firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 5), "结束耗时编辑需要完成键或节点名称字段")
        node.tap()
    }
    /// 弹层内容不在主列表里。滑动整个窗口会把弹层关掉，所以只滚动最前面的列表。
    private func revealPopover(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "弹层中应出现 \(element.identifier)")
        let scroller = app.collectionViews.allElementsBoundByIndex.last
        for _ in 0..<6 {
            if element.exists, element.isHittable { return }
            scroller?.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "弹层内无法点到 \(element.identifier)")
    }
    @discardableResult private func find(_ element: XCUIElement) -> Bool {
        func visible() -> Bool {
            guard element.exists && element.isHittable else { return false }
            let frame = element.frame
            if ["project.saveTemplate", "template.detail.rename", "template.detail.delete"].contains(element.identifier) { return true }
            if frame.maxY <= 112 && frame.minY >= 44 { return true } // Native navigation controls.
            let tab = app.tabBars.firstMatch
            let bottom = tab.exists && tab.isHittable ? tab.frame.minY - 6 : app.windows.firstMatch.frame.maxY - 24
            return frame.minY >= 112 && frame.maxY <= bottom
        }
        for _ in 0..<8 { if visible() { return true }; app.swipeUp() }
        for _ in 0..<12 { if visible() { return true }; app.swipeDown() }
        return visible()
    }
    private func reveal(_ element: XCUIElement) {
        if !find(element) { capture("unrevealed-target"); XCTFail("Cannot reveal target: \(element.description)") }
    }
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "template-\(name)"; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "tree-\(name)"; tree.lifetime = .keepAlways; add(tree)
    }
}
