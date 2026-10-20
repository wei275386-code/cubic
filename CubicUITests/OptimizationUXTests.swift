import XCTest

/// 三项优化的真机 UI/UX 验收：行动页顺序、项目“修改详情”层级、默认验收（完成自身）。
/// 使用 Debug-only QA 数据区（`-CubicWorkCalendarQA(-Reset)`），不触碰用户普通数据。
@MainActor final class OptimizationUXTests: XCTestCase {
    func testMarkdownQuickCreateValidatesPreviewsAndPersistsStructure() throws {
        let app = launchQA()
        openProjectTab(app)
        let create = app.buttons["projects.createMarkdown"]
        XCTAssertTrue(create.waitForExistence(timeout: 10)); create.tap()
        let source = app.textViews["editor.markdown.source"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap(); source.typeText("项目, 02.30")
        XCTAssertFalse(app.buttons["editor.markdown.save"].isEnabled)
        let validation = app.staticTexts["editor.markdown.validation"]
        reveal(app, validation)
        XCTAssertTrue(validation.exists)
        XCTAssertTrue(validation.label.contains("第 1 行"))
        let example = app.buttons["editor.markdown.example"]
        reveal(app, example)
        example.tap()
        XCTAssertTrue(app.buttons["editor.markdown.save"].isEnabled)
        // End editing to expose the preview on a compact physical device.
        app.swipeUp()
        let preview = app.staticTexts["识别预览：2 个节点 · 4 项工作"]
        reveal(app, preview, attempts: 4)
        XCTAssertTrue(preview.exists)
        capture("markdown-preview")
        app.buttons["editor.markdown.save"].tap()
        XCTAssertTrue(app.navigationBars["项目详情"].waitForExistence(timeout: 15))
        let firstNode = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value CONTAINS %@", "project.structure.node.name.", "支出分类")).firstMatch
        XCTAssertTrue(firstNode.waitForExistence(timeout: 10))
        let firstWork = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value CONTAINS %@", "project.structure.item.name.", "大额消费校对")).firstMatch
        reveal(app, firstWork)
        XCTAssertTrue(firstWork.exists)
        let estimate = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "project.structure.item.duration.")).firstMatch
        reveal(app, estimate)
        XCTAssertEqual(estimate.value as? String, "120")
        let secondNode = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value CONTAINS %@", "project.structure.node.name.", "复盘")).firstMatch
        reveal(app, secondNode)
        XCTAssertTrue(secondNode.exists)
        let lastWork = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value CONTAINS %@", "project.structure.item.name.", "具体调整目标")).firstMatch
        reveal(app, lastWork)
        XCTAssertTrue(lastWork.exists)
        capture("markdown-created-structure")
        app.terminate()
        app.launchArguments = ["-CubicWorkCalendarQA"]
        app.launch()
        openProjectTab(app)
        let project = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "projects.project.", "家庭财务复盘")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.tap()
        reveal(app, firstWork)
        XCTAssertTrue(firstWork.exists)
        capture("markdown-restored-structure")
    }

    func testInlineDurationEditsPersistAndDefaultDependenciesAreVisible() throws {
        let app = launchQA()
        openProjectTab(app)
        app.buttons["projects.project.qa-project"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["项目详情"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["project.edit"].exists)
        XCTAssertFalse(app.textFields["editor.node.outcome"].exists)
        let duration = app.textFields["project.structure.item.duration.qa-drag"]
        reveal(app, duration)
        XCTAssertEqual(duration.value as? String, "45")
        duration.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        duration.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "75")
        let info = app.buttons["project.structure.item.info.qa-drag"]
        let done = app.buttons["project.structure.keyboard.done"]
        if done.waitForExistence(timeout: 3) {
            done.tap()
        } else {
            info.tap()
        }
        XCTAssertEqual(duration.value as? String, "75", "耗时应在结束编辑前写入 75")
        if !app.buttons["project.structure.item.history.qa-drag"].exists {
            reveal(app, info)
            info.tap()
        }
        XCTAssertTrue(app.navigationBars["项目详情"].exists, "Saving must stay on the hierarchy")
        capture("project-inline-duration-saved")
        let history = app.buttons["project.structure.item.history.qa-drag"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        XCTAssertTrue(app.staticTexts["45 分钟 → 1 小时 15 分"].waitForExistence(timeout: 5))
        capture("project-inline-duration-history-saved")
        app.buttons["project.structure.item.info.done.qa-drag"].tap()
        let predecessor = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "project.structure.item.predecessors.", "前置：QA 删除工作")).firstMatch
        reveal(app, predecessor)
        XCTAssertTrue(predecessor.exists)
        capture("project-default-predecessor")
        app.terminate()
        app.launchArguments = ["-CubicWorkCalendarQA"]
        app.launch()
        openProjectTab(app)
        app.buttons["projects.project.qa-project"].firstMatch.tap()
        reveal(app, duration)
        XCTAssertEqual(duration.value as? String, "75")
        capture("project-inline-duration-restored")
        reveal(app, info)
        info.tap()
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        XCTAssertTrue(app.staticTexts["45 分钟 → 1 小时 15 分"].waitForExistence(timeout: 5))
        capture("project-inline-duration-history-restored")
        app.buttons["project.structure.item.info.done.qa-drag"].tap()
    }

    private func launchQA() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CubicWorkCalendarQA", "-CubicWorkCalendarQAReset"]
        app.launch()
        return app
    }
    func testActionsHideArchivedProjectWorkAndRestoreIt() throws {
        let app = launchQA()
        XCTAssertTrue(app.buttons["行动"].waitForExistence(timeout: 20))
        app.buttons["行动"].tap()
        for id in ["qa-drag", "qa-delete"] {
            XCTAssertTrue(app.buttons["action.trial.\(id)"].waitForExistence(timeout: 15))
        }
        openProjectTab(app)
        let project = app.buttons["projects.project.qa-project"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        let archive = app.buttons["project.archive"]
        app.buttons["project.operations"].tap()
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        XCTAssertTrue(archive.isHittable); archive.tap()
        app.buttons["project.operations"].tap()
        XCTAssertTrue(app.buttons["恢复显示"].waitForExistence(timeout: 10))
        app.tap()
        app.buttons["行动"].tap()
        XCTAssertTrue(app.staticTexts["暂时没有可开始的工作"].waitForExistence(timeout: 10))
        for id in ["qa-drag", "qa-delete"] { XCTAssertFalse(app.buttons["action.trial.\(id)"].exists) }
        XCTAssertFalse(app.staticTexts["QA 工作删除与日历"].exists, "Archived project scheduling reminders must disappear immediately")
        capture("actions-project-archived")

        app.terminate()
        app.launchArguments = ["-CubicWorkCalendarQA"]
        app.launch()
        XCTAssertTrue(app.buttons["行动"].waitForExistence(timeout: 20))
        app.buttons["行动"].tap()
        XCTAssertTrue(app.staticTexts["暂时没有可开始的工作"].waitForExistence(timeout: 10))
        for id in ["qa-drag", "qa-delete"] { XCTAssertFalse(app.buttons["action.trial.\(id)"].exists) }
        XCTAssertFalse(app.staticTexts["QA 工作删除与日历"].exists)

        openProjectTab(app)
        let includeArchived = app.switches["projects.includeArchived"]
        XCTAssertTrue(includeArchived.waitForExistence(timeout: 10))
        includeArchived.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.tap()
        app.buttons["project.operations"].tap()
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        XCTAssertTrue(archive.isHittable); archive.tap()
        app.buttons["project.operations"].tap()
        XCTAssertTrue(app.buttons["归档项目"].waitForExistence(timeout: 10))
        app.tap()
        app.buttons["行动"].tap()
        for id in ["qa-delete"] {
            XCTAssertTrue(app.buttons["action.trial.\(id)"].waitForExistence(timeout: 15))
        }
        capture("actions-project-restored")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func openProjectTab(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["项目"].waitForExistence(timeout: 20))
        app.buttons["项目"].tap()
    }
    /// List 行惰性渲染；先向下扫，找不到再向上扫。
    private func reveal(_ app: XCUIApplication, _ target: XCUIElement, attempts: Int = 10) {
        for _ in 0..<attempts { if target.exists, target.isHittable { return }; app.swipeUp() }
        for _ in 0..<(attempts * 2) { if target.exists, target.isHittable { return }; app.swipeDown() }
        for _ in 0..<(attempts * 2) { if target.exists, target.isHittable { return }; app.swipeUp() }
    }
    /// 完成一项工作：确认完成 → 跳过反馈（直接完成待办）。
    private func completeWork(_ app: XCUIApplication, _ id: String) {
        let info = app.buttons["project.structure.item.info.\(id)"]
        reveal(app, info)
        XCTAssertTrue(info.isHittable, "应能滚动到工作 \(id)：\(app.debugDescription)")
        info.tap()
        let row = app.buttons["project.item.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "工作信息顶部应有执行与投入记录")
        XCTAssertTrue(row.isHittable, "执行入口应在弹层顶部，不能靠滑动主列表露出")
        row.tap()
        XCTAssertTrue(app.navigationBars["工作详情"].waitForExistence(timeout: 10), "执行入口应进入工作详情：\(app.debugDescription)")
        let complete = app.buttons["work.complete"]
        if !(complete.exists && complete.isHittable) { reveal(app, complete) }
        XCTAssertTrue(complete.isHittable, "工作详情应能完成：\(app.debugDescription)")
        complete.tap()
        let confirm = app.buttons["work.complete.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let skip = app.buttons["editor.record.skip"].firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "确认完成后应弹出可跳过的反馈表单")
        skip.tap()
        XCTAssertTrue(app.navigationBars["工作详情"].waitForExistence(timeout: 10))
        app.navigationBars["工作详情"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["项目详情"].waitForExistence(timeout: 10))
    }

    /// 优化三：行动页“现在可开始”位于第一个内容区。
    func testActionsPutsAvailableFirst() throws {
        let app = launchQA()
        XCTAssertTrue(app.buttons["行动"].waitForExistence(timeout: 20))
        app.buttons["行动"].tap()
        let available = app.staticTexts["现在可开始"]
        XCTAssertTrue(available.waitForExistence(timeout: 15), "行动页应显示“现在可开始”：\(app.debugDescription)")
        capture("actions-available-first")
        XCTAssertLessThan(available.frame.minY, app.frame.height * 0.85, "“现在可开始”应位于首个内容区（页头之后）")
        // 回顾与跟进已移到末尾：初始视口内不应出现（若已渲染则须在“现在可开始”之后）。
        let review = app.staticTexts["回顾与跟进"]
        if review.exists { XCTAssertGreaterThan(review.frame.minY, available.frame.minY) }
    }

    /// 优化二：项目“修改详情”以缩进层级展示“节点 -> 子工作”，并能在本页新增节点。
    func testProjectStructureHierarchy() throws {
        let app = launchQA()
        openProjectTab(app)
        let project = app.buttons["projects.project.qa-project"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.tap()
        XCTAssertTrue(app.navigationBars["项目详情"].waitForExistence(timeout: 10))
        let node = app.buttons["project.structure.node.qa-node"]
        XCTAssertTrue(node.waitForExistence(timeout: 10))
        // 子工作默认展开，层级列表直接可见。
        let work = app.textFields["project.structure.item.name.qa-drag"]
        reveal(app, work)
        XCTAssertTrue(work.exists)
        capture("structure-hierarchy")
        // 本页新增节点（按钮可能在屏幕下方）。
        let addNode = app.buttons["project.structure.addNode"]
        reveal(app, addNode)
        XCTAssertTrue(addNode.isHittable, "修改详情应能新增节点：\(app.debugDescription)")
        addNode.tap()
        let name = app.textFields["editor.node.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap(); name.typeText("QA 新节点")
        app.buttons["editor.node.save"].tap()
        let nodeQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "project.structure.node."))
        XCTAssertTrue(nodeQuery.firstMatch.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(nodeQuery.count, 2)
        capture("structure-after-add-node")
    }

    /// 优化一：没有主动添加验收条件的节点显示“默认验收条件：完成自身”，且不再强制添加。
    func testDefaultAcceptanceDoesNotForceConditions() throws {
        let app = launchQA()
        openProjectTab(app)
        let project = app.buttons["projects.project.qa-project"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.tap()
        let info = app.buttons["project.structure.node.info.qa-node"]
        reveal(app, info)
        XCTAssertTrue(info.isHittable)
        info.tap()
        let node = app.buttons["project.structure.node.acceptance.qa-node"]
        XCTAssertTrue(node.waitForExistence(timeout: 5))
        node.tap()
        XCTAssertTrue(app.buttons["node.complete.qa-node"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["node.addRequiredAcceptance"].exists, "不应再强制“添加验收条件”")
        let note = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "默认验收条件")).firstMatch
        capture("node-default-acceptance")
        XCTAssertTrue(note.waitForExistence(timeout: 5), "节点详情应显示默认验收说明：\(app.debugDescription)")
    }

    /// 优化一（端到端）：完成全部子工作后，节点无需添加验收条件即可确认完成。
    func testCompletingAllWorksAllowsNodeCompletionWithoutAcceptance() throws {
        let app = launchQA()
        openProjectTab(app)
        let project = app.buttons["projects.project.qa-project"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        XCTAssertTrue(app.navigationBars["项目详情"].waitForExistence(timeout: 10))
        completeWork(app, "qa-delete")
        completeWork(app, "qa-drag")
        completeWork(app, "qa-keep")
        let info = app.buttons["project.structure.node.info.qa-node"]
        reveal(app, info)
        XCTAssertTrue(info.isHittable)
        info.tap()
        let node = app.buttons["project.structure.node.acceptance.qa-node"]
        XCTAssertTrue(node.waitForExistence(timeout: 5))
        node.tap()
        // 未添加任何验收条件：验收区显示默认说明，且没有自动创建的验收项。
        let defaultNote = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "默认验收条件")).firstMatch
        XCTAssertTrue(defaultNote.waitForExistence(timeout: 5), "应显示默认验收说明：\(app.debugDescription)")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "acceptance.accept.")).firstMatch.exists)
        let nodeComplete = app.buttons["node.complete.qa-node"]
        XCTAssertTrue(nodeComplete.waitForExistence(timeout: 5))
        XCTAssertTrue(nodeComplete.isHittable, "节点应可在无验收条件下完成：\(app.debugDescription)")
        nodeComplete.tap()
        let completed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已完成")).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 10), "节点应在无验收条件下直接完成：\(app.debugDescription)")
        capture("node-completed-without-acceptance")
    }

    /// 日历“建议的最晚开始时间”按叶子工作去重：每项工作一行，不再显示节点聚合。
    func testCalendarLatestStartShowsEachLeafWorkOnce() throws {
        let app = launchQA()
        XCTAssertTrue(app.buttons["日历"].waitForExistence(timeout: 20))
        app.buttons["日历"].tap()
        XCTAssertTrue(app.navigationBars["日历"].waitForExistence(timeout: 10))
        let section = app.staticTexts["建议的最晚开始时间"]
        reveal(app, section)
        XCTAssertTrue(section.exists, "日历应显示“建议的最晚开始时间”：\(app.debugDescription)")
        for id in ["qa-drag", "qa-delete", "qa-keep"] {
            let row = app.descendants(matching: .any)["calendar.latestStart.\(id)"]
            reveal(app, row)
            XCTAssertTrue(row.exists, "建议条目应按工作展示：\(id)")
            XCTAssertEqual(row.identifier, "calendar.latestStart.\(id)")
        }
        XCTAssertFalse(app.descendants(matching: .any)["calendar.latestStart.qa-node"].exists, "节点聚合不应作为建议条目出现")
        capture("calendar-latest-start-deduped")
    }

    /// 新建工作的“归属与共享”不再列出已归档项目。
    func testInboxNewWorkOwnershipExcludesArchivedProject() throws {
        let app = launchQA()
        openProjectTab(app)
        let project = app.buttons["projects.project.qa-project"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        XCTAssertTrue(app.navigationBars["项目详情"].waitForExistence(timeout: 10))
        let archive = app.buttons["project.archive"]
        app.buttons["project.operations"].tap()
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        XCTAssertTrue(archive.isHittable, "应能归档项目：\(app.debugDescription)")
        archive.tap()
        XCTAssertTrue(app.buttons["收件箱"].waitForExistence(timeout: 10)); app.buttons["收件箱"].tap()
        let newItem = app.buttons["inbox.newItem"]
        XCTAssertTrue(newItem.waitForExistence(timeout: 10)); newItem.tap()
        XCTAssertTrue(app.navigationBars["新建工作"].waitForExistence(timeout: 10))
        let nodePicker = app.buttons["editor.item.node"]
        reveal(app, nodePicker)
        XCTAssertTrue(app.staticTexts["可关联多个项目，共用同一份进度和投入。移除关联不会删除原工作。"].exists, "应能滚到“归属与共享”：\(app.debugDescription)")
        XCTAssertFalse(app.switches["editor.item.project.qa-project"].exists, "归档项目不应出现在归属与共享：\(app.debugDescription)")
        capture("inbox-new-work-excludes-archived")
    }

    /// 日历页不再残留显示归档（旧数据）项目。
    func testCalendarHidesArchivedProject() throws {
        let app = launchQA()
        openProjectTab(app)
        let project = app.buttons["projects.project.qa-project"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        XCTAssertTrue(app.navigationBars["项目详情"].waitForExistence(timeout: 10))
        let archive = app.buttons["project.archive"]
        app.buttons["project.operations"].tap()
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        XCTAssertTrue(archive.isHittable, "应能归档项目：\(app.debugDescription)")
        archive.tap()
        XCTAssertTrue(app.buttons["日历"].waitForExistence(timeout: 10))
        app.buttons["日历"].tap()
        XCTAssertTrue(app.navigationBars["日历"].waitForExistence(timeout: 10))
        let empty = app.staticTexts["还没有项目，去项目页创建一个。"]
        reveal(app, empty)
        XCTAssertTrue(empty.exists, "日历项目区应无归档项目：\(app.debugDescription)")
        XCTAssertFalse(app.descendants(matching: .any)["calendar.project.qa-project"].exists, "归档项目不应在日历残留显示")
        capture("calendar-hides-archived-project")
    }
}
