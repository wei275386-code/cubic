import XCTest
import Darwin

/// Bounded, independent physical acceptance using only Documents/CubicQA.
@MainActor final class ProjectTemplateFinalUITests: XCTestCase {
    private let app = XCUIApplication()

    // Physical acceptance can reset isolated QA data or resume a stored checkpoint.
    // Select exactly one method in the test runner environment; ordinary suites skip it.
    private func requirePhysicalQA(_ function: String) throws {
        let method = function.replacingOccurrences(of: "()", with: "")
        guard ProcessInfo.processInfo.environment["CUBIC_PROJECT_TEMPLATE_QA_TEST"] == method else {
            throw XCTSkip("Physical template QA is opt-in. Set CUBIC_PROJECT_TEMPLATE_QA_TEST to the selected method and use -only-testing.")
        }
    }
    private let title = "QA 模板重命名"

    func test01SaveCreateRenamePersist() throws {
        try requirePhysicalQA(#function)
        continueAfterFailure = false
        app.launchArguments = ["-CubicWorkCalendarQA", "-CubicWorkCalendarQAReset"]
        app.launch()
        root(); tap(app.buttons["projects.project.qa-project"])
        let originalDeadline = deadlineDescription()
        tap(app.buttons["project.operations"]); tap(app.buttons["project.saveTemplate"])
        XCTAssertEqual(app.textFields["template.editor.name"].value as? String, "QA 工作删除与日历")
        capture("01-save-default-title")
        preview(); capture("02-save-preview-45min")
        tap(app.buttons["template.editor.save"])
        finishFirstInstance(originalDeadline: originalDeadline)
    }

    /// Resume from the template already saved by the first bounded run; never reset QA state here.
    func test01bCreateRenamePersist() throws {
        try requirePhysicalQA(#function)
        continueAfterFailure = false
        app.launchArguments = ["-CubicWorkCalendarQA"]; app.launch()
        root(); XCTAssertEqual(projectRows().count, 1)
        tap(app.buttons["projects.project.qa-project"])
        let originalDeadline = deadlineDescription()
        finishFirstInstance(originalDeadline: originalDeadline)
    }

    private func finishFirstInstance(originalDeadline: String) {
        root(); tap(app.buttons["projects.templates"]); tap(templateRow())
        tap(app.buttons["template.detail.create"])
        XCTAssertTrue(app.datePickers["template.create.deadline.date"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields.count, 0, "Only deadline is editable")
        tap(app.datePickers["template.create.deadline.date"])
        let day = app.buttons["10月20日 星期二"].firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 5), app.debugDescription); day.tap()
        if app.buttons["PopoverDismissRegion"].exists {
            app.buttons["PopoverDismissRegion"].coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.20)).tap()
        }
        XCTAssertTrue(app.datePickers["template.create.deadline.date"].debugDescription.contains("20日"))
        capture("03-create-changed-cutoff")
        preview(); capture("04-create-readonly-preview")
        tap(app.buttons["template.create.save"])
        XCTAssertTrue(app.navigationBars["项目详情"].waitForExistence(timeout: 15))
        let instance = structure()
        capture("05-first-instance-structure")
        XCTAssertTrue(deadlineDescription().contains("20日"), "Destination deadline must persist")
        root(); XCTAssertEqual(projectRows().count, 2)
        let projectIDs = projectRows().allElementsBoundByIndex.map(\.identifier)
        record("first-instance-identities", "projects=\(projectIDs)\nstructure=\(instance)")
        tap(app.buttons["projects.project.qa-project"])
        XCTAssertEqual(deadlineDescription(), originalDeadline, "Creating a template instance must not change source deadline")
        root(); tap(app.buttons["projects.templates"]); tap(templateRow())
        tap(app.buttons["template.detail.operations"]); tap(app.buttons["template.detail.rename"])
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let n = (field.value as? String ?? "").utf16.count
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: n + 2) + title)
        XCTAssertEqual(field.value as? String, title)
        app.alerts.buttons["保存"].tap()
        waitForRenamedTitle()
        XCTAssertEqual(app.staticTexts["template.detail.title"].label, title)
        XCTAssertEqual(app.staticTexts["template.preview.project"].label, "QA 工作删除与日历")
        capture("06-renamed-title-original-payload-name")
        app.terminate(); app.launchArguments = ["-CubicWorkCalendarQA"]; app.launch()
        root(); XCTAssertEqual(projectRows().count, 2)
        tap(app.buttons["projects.templates"]); tap(templateRow())
        XCTAssertEqual(app.staticTexts["template.detail.title"].label, title)
        preview(); capture("07-relaunch-persisted-snapshot")
    }

    /// Read the result of the already executed rename, then verify a second cold launch.
    func test01cVerifyRenameAndRelaunch() throws {
        try requirePhysicalQA(#function)
        continueAfterFailure = false
        app.launchArguments = ["-CubicWorkCalendarQA"]; app.launch()
        root(); XCTAssertEqual(projectRows().count, 2)
        tap(app.buttons["projects.templates"]); tap(templateRow())
        waitForRenamedTitle()
        XCTAssertEqual(app.staticTexts["template.preview.project"].label, "QA 工作删除与日历")
        capture("06-renamed-title-original-payload-name")
        preview(); capture("07-relaunch-persisted-snapshot")
        app.terminate(); app.launch()
        root(); XCTAssertEqual(projectRows().count, 2)
        tap(app.buttons["projects.templates"]); tap(templateRow())
        waitForRenamedTitle(); preview(); capture("07b-second-relaunch-persisted-snapshot")
    }

    private func waitForRenamedTitle() {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", title), object: app.staticTexts["template.detail.title"])
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: 10), .completed, "Rename must persist and update the displayed title")
    }

    func test02SecondInstanceDeleteRetainsProjects() throws {
        try requirePhysicalQA(#function)
        continueAfterFailure = false
        app.launchArguments = ["-CubicWorkCalendarQA"]; app.launch()
        root(); XCTAssertEqual(projectRows().count, 2, "First bounded test must have completed")
        let firstProject = projectRows().allElementsBoundByIndex.first { $0.identifier != "projects.project.qa-project" }!
        let firstProjectID = firstProject.identifier
        tap(firstProject); let first = structure()
        root(); tap(app.buttons["projects.templates"]); tap(templateRow())
        XCTAssertEqual(app.staticTexts["template.detail.title"].label, title)
        tap(app.buttons["template.detail.create"]); tap(app.buttons["template.create.save"])
        XCTAssertTrue(app.navigationBars["项目详情"].waitForExistence(timeout: 15))
        let second = structure()
        XCTAssertTrue(first.isDisjoint(with: second), "Project instances need unique node/work identities")
        capture("08-second-instance-same-content-new-identities")
        root(); let ids = collectProjectIDs()
        XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(ids.contains(firstProjectID) && ids.contains("projects.project.qa-project"))
        record("two-instance-identities", "projects=\(ids.sorted())\nfirst=\(first.sorted())\nsecond=\(second.sorted())")
        capture("09-two-project-instances")
        tap(app.buttons["projects.templates"]); tap(templateRow())
        tap(app.buttons["template.detail.operations"]); tap(app.buttons["template.detail.delete"])
        capture("10-delete-confirmation")
        confirmDelete()
        XCTAssertTrue(app.staticTexts["还没有项目模板"].waitForExistence(timeout: 10))
        capture("11-deleted-template-list")
        root(); XCTAssertEqual(collectProjectIDs(), ids)
        capture("12-both-created-projects-retained")
        app.terminate(); app.launchArguments = ["-CubicWorkCalendarQA"]; app.launch()
        root(); XCTAssertEqual(collectProjectIDs(), ids)
        tap(app.buttons["projects.templates"])
        XCTAssertTrue(app.staticTexts["还没有项目模板"].waitForExistence(timeout: 10))
        capture("13-deletion-and-projects-persisted")
    }

    /// Continue after the second instance has been created; verify complete lazy-list membership.
    func test03DeleteRetainsBothInstances() throws {
        try requirePhysicalQA(#function)
        continueAfterFailure = false
        app.launchArguments = ["-CubicWorkCalendarQA"]; app.launch()
        root(); let ids = collectProjectIDs()
        XCTAssertEqual(ids.count, 3, "Source and both independently created projects must be present")
        XCTAssertTrue(ids.contains("projects.project.qa-project"))
        record("three-project-identities-before-delete", ids.sorted().joined(separator: "\n"))
        capture("09-two-project-instances")
        tap(app.buttons["projects.templates"]); capture("09a-renamed-template-list")
        tap(templateRow()); waitForRenamedTitle()
        tap(app.buttons["template.detail.operations"]); tap(app.buttons["template.detail.delete"])
        capture("10-delete-confirmation")
        confirmDelete()
        XCTAssertTrue(app.staticTexts["还没有项目模板"].waitForExistence(timeout: 10))
        capture("11-deleted-template-list")
        root(); XCTAssertEqual(collectProjectIDs(), ids)
        capture("12-both-created-projects-retained")
        app.terminate(); app.launch()
        root(); XCTAssertEqual(collectProjectIDs(), ids)
        record("three-project-identities-after-relaunch", ids.sorted().joined(separator: "\n"))
        tap(app.buttons["projects.templates"])
        XCTAssertTrue(app.staticTexts["还没有项目模板"].waitForExistence(timeout: 10))
        capture("13-deletion-and-projects-persisted")
    }

    private func collectProjectIDs() -> Set<String> {
        var ids = Set(projectRows().allElementsBoundByIndex.map(\.identifier))
        capture("projects-visible-top")
        for _ in 0..<3 {
            app.swipeUp()
            ids.formUnion(projectRows().allElementsBoundByIndex.map(\.identifier))
        }
        capture("projects-visible-bottom")
        for _ in 0..<3 { app.swipeDown() }
        return ids
    }

    private func confirmDelete() {
        // Native confirmation contains nested buttons with the same AX ID. Scope to the actual Sheet.
        let button = app.sheets["删除这个模板？"].buttons["template.delete.confirm"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isHittable)
        XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        button.tap()
    }

    private func deadlineDescription() -> String {
        tap(app.buttons["project.operations"]); tap(app.buttons["编辑项目属性"])
        let date = app.datePickers["editor.project.deadline.date"]
        reveal(date); XCTAssertEqual(app.switches["editor.project.deadline.enabled"].value as? String, "1")
        let value = date.buttons.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }.joined(separator: " | ")
        XCTAssertFalse(value.isEmpty, "Native date picker must expose date/time values")
        record("project-deadline", value); capture("project-deadline")
        tap(app.buttons["editor.project.cancel"])
        return value
    }
    private func preview() {
        let marker: XCUIElement
        if app.textFields["template.editor.name"].exists {
            marker = app.textFields["template.editor.name"]
        } else if app.datePickers["template.create.deadline.date"].exists {
            marker = app.datePickers["template.create.deadline.date"]
        } else {
            marker = app.staticTexts["template.preview.summary"]
        }
        let index = (0..<app.collectionViews.count).first {
            app.collectionViews.element(boundBy: $0).descendants(matching: .any)[marker.identifier].exists
        }!
        // Freeze the plain collection index. A containing(marker) query stops matching when a lazy cell scrolls out.
        let foreground = app.collectionViews.element(boundBy: index)
        let summary = foreground.staticTexts["template.preview.summary"]
        reveal(summary); XCTAssertEqual(summary.label, "1 个节点 · 3 项工作 · 2 条前置关系")
        XCTAssertEqual(foreground.staticTexts["template.preview.project"].label, "QA 工作删除与日历")
        XCTAssertEqual(foreground.staticTexts["template.preview.duration"].label, "总耗时：1 小时 45 分")
        let work = foreground.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "耗时：45 分钟")).firstMatch
        reveal(work); XCTAssertTrue(work.exists)
        let edge = foreground.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "前置：QA 删除工作")).firstMatch
        reveal(edge); XCTAssertTrue(edge.exists)
        XCTAssertFalse(foreground.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "时间估计")).firstMatch.exists)
    }
    private func structure() -> Set<String> {
        let node = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "project.structure.node.name.", "QA 交付")).firstMatch
        reveal(node); XCTAssertTrue(node.exists)
        capture("instance-node-\(node.identifier)")
        var ids: Set<String> = [node.identifier]
        for (name, minutes) in [("QA 删除工作", "30"), ("QA 拖拽时间块", "45"), ("QA 保留工作", "30")] {
            let work = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "project.structure.item.name.", name)).firstMatch
            reveal(work); XCTAssertTrue(work.exists)
            let id = work.identifier.replacingOccurrences(of: "project.structure.item.name.", with: "")
            ids.insert(work.identifier)
            let duration = app.textFields["project.structure.item.duration.\(id)"]
            reveal(duration); XCTAssertEqual(duration.value as? String, minutes)
            let predecessors = app.buttons["project.structure.item.predecessors.\(id)"]
            reveal(predecessors)
            XCTAssertEqual(predecessors.label, name == "QA 删除工作" ? "前置：无，点击选择" : "前置：QA 删除工作")
            capture("instance-work-\(name)")
            XCTAssertFalse(["qa-drag", "qa-delete", "qa-keep"].contains(id))
            // Compact rows keep status in the real info popover. Check that
            // public UI instead of assuming the old summary cell is present.
            tap(app.buttons["project.structure.item.info.\(id)"])
            let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "未开工")).firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 5) && status.isHittable)
            capture("instance-work-status-\(name)")
            app.buttons["project.structure.item.info.done.\(id)"].tap()
        }
        XCTAssertEqual(ids.count, 4)
        return ids
    }
    private func projectRows() -> XCUIElementQuery { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "projects.project.")) }
    private func templateRow() -> XCUIElement { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "templates.template.")).firstMatch }
    private func root() {
        let tab = app.tabBars.buttons["项目"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10)); tab.tap()
        for _ in 0..<4 {
            if app.navigationBars["项目"].exists { return }
            app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.navigationBars["项目"].exists)
    }
    private func tap(_ element: XCUIElement) { reveal(element); element.tap() }
    private func reveal(_ element: XCUIElement) {
        func visible() -> Bool {
            guard element.exists && element.isHittable else { return false }
            if ["project.saveTemplate", "编辑项目属性", "template.detail.rename", "template.detail.delete"].contains(element.identifier) { return true }
            let f = element.frame
            if f.maxY <= 112 && f.minY >= 44 { return true }
            let bar = app.tabBars.firstMatch
            let bottom = bar.exists && bar.isHittable ? bar.frame.minY - 6 : app.windows.firstMatch.frame.maxY - 24
            return f.minY >= 112 && f.maxY <= bottom
        }
        if element.waitForExistence(timeout: 5) && visible() { return }
        for _ in 0..<5 { app.swipeUp(); if visible() { return } }
        for _ in 0..<7 { app.swipeDown(); if visible() { return } }
        capture("unrevealed-target"); XCTFail("Cannot reveal \(element.description)")
    }
    private func record(_ name: String, _ value: String) {
        let a = XCTAttachment(string: value); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func capture(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = "final-template-\(name)"; a.lifetime = .keepAlways; add(a)
        record("tree-\(name)", app.debugDescription)
    }
}

/// Independent node-sequence acceptance. Opt-in and restricted to Documents/CubicQA.
/// Kept in an existing test source to avoid changes to the user's Xcode project.
@MainActor final class NodeSequenceUITests: XCTestCase {
    private let app = XCUIApplication()
    private let secondName = "QA 第二节点：核对全年消费分类并检查所有中文长名称"
    private let thirdName = "QA 第三节点：提交总结"
    private var measured: [(String, CGRect)] = []

    private func requirePhysicalQA(_ function: String) throws {
        let method = function.replacingOccurrences(of: "()", with: "")
        guard ProcessInfo.processInfo.environment["CUBIC_NODE_SEQUENCE_QA_TEST"] == method else {
            throw XCTSkip("Opt-in physical QA. Select this method with CUBIC_NODE_SEQUENCE_QA_TEST and -only-testing.")
        }
        var size = 0
        XCTAssertEqual(sysctlbyname("hw.machine", nil, &size, nil, 0), 0)
        var buffer = [CChar](repeating: 0, count: size)
        XCTAssertEqual(sysctlbyname("hw.machine", &buffer, &size, nil, 0), 0)
        let model = String(cString: buffer)
        record("physical-device", "hw.machine=\(model)\nOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        XCTAssertEqual(model, "iPhone14,4", "QA must use the connected iPhone 13 mini")
        continueAfterFailure = false
    }

    func test01CreateMoveAndRelaunch() throws {
        try requirePhysicalQA(#function)
        app.launchArguments = ["-CubicWorkCalendarQA", "-CubicWorkCalendarQAReset"]
        app.launch(); openProject()
        tap(app.buttons["project.structure.node.qa-node"])
        let b = addNode(secondName)
        tap(app.buttons["project.structure.node.\(b)"])
        let c = addNode(thirdName)
        tap(app.buttons["project.structure.node.\(c)"])
        capture("01-added-three-nodes")
        tap(app.buttons["project.structure.reorderNodes"])
        checkOrder(["qa-node", b, c])
        XCTAssertFalse(app.buttons["project.nodeOrder.up.qa-node"].isEnabled)
        reveal(app.buttons["project.nodeOrder.down.\(c)"])
        XCTAssertFalse(app.buttons["project.nodeOrder.down.\(c)"].isEnabled)
        capture("02-sheet-initial-bottom-disabled")
        for id in ["qa-node", b, c] {
            for direction in ["up", "down"] {
                let e = app.buttons["project.nodeOrder.\(direction).\(id)"]
                reveal(e); measured.append((e.identifier, e.frame))
            }
        }
        tap(app.buttons["project.nodeOrder.up.\(b)"])
        waitLabel("project.nodeOrder.name.\(b)", "1. \(secondName)")
        checkOrder([b, "qa-node", c])
        XCTAssertFalse(app.buttons["project.nodeOrder.up.\(b)"].isEnabled)
        XCTAssertTrue(app.staticTexts["前置：\(secondName)"].exists)
        capture("03-moved-up-long-name")
        tap(app.buttons["project.nodeOrder.down.\(b)"])
        waitLabel("project.nodeOrder.name.qa-node", "1. QA 交付")
        checkOrder(["qa-node", b, c]); capture("04-moved-down")
        tap(app.buttons["project.nodeOrder.up.\(b)"])
        waitLabel("project.nodeOrder.name.\(b)", "1. \(secondName)")
        let done = app.buttons["project.nodeOrder.done"]
        measured.append((done.identifier, done.frame)); tap(done)
        verifyDetails(b: b, c: c)
        capture("05-detail-updated-predecessor")
        app.terminate(); app.launchArguments = ["-CubicWorkCalendarQA"]; app.launch()
        openProject(); verifyDetails(b: b, c: c)
        capture("06-relaunch-detail-persisted")
        tap(app.buttons["project.structure.reorderNodes"])
        checkOrder([b, "qa-node", c]); capture("07-relaunch-order-persisted")
        tap(app.buttons["project.nodeOrder.done"])
        record("target-frames", measured.map { "\($0.0)=\($0.1)" }.joined(separator: "\n"))
        for (id, frame) in measured {
            XCTAssertGreaterThanOrEqual(frame.height, 44, "\(id) height")
            XCTAssertGreaterThanOrEqual(frame.width, 44, "\(id) width")
        }
    }

    /// Uses the stored isolated checkpoint from test01; does not reset any data.
    /// 前置新增只能选工作。节点顺序造成的循环由 Core 的 NodeSequenceTests 覆盖。
    func test02CycleRollback() throws {
        try requirePhysicalQA(#function)
        app.launchArguments = ["-CubicWorkCalendarQA"]; app.launch(); openProject()
        tap(app.buttons["project.structure.item.info.qa-delete"])
        let detail = app.buttons["project.item.qa-delete"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        detail.tap()
        tap(app.buttons["work.addDependency"])
        XCTAssertFalse(app.buttons["editor.dependency.kind"].exists)
        XCTAssertFalse(app.buttons["节点通过验收"].exists)
        XCTAssertFalse(app.staticTexts["节点通过验收"].exists)
        XCTAssertTrue(app.textFields["editor.dependency.search"].waitForExistence(timeout: 5))
        let affiliation = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "-＞")).firstMatch
        XCTAssertTrue(affiliation.waitForExistence(timeout: 5), app.debugDescription)
        capture("08-work-only-predecessors")
    }

    private func addNode(_ name: String) -> String {
        tap(app.buttons["project.structure.addNode"])
        let field = app.textFields["editor.node.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText(name)
        tap(app.buttons["editor.node.save"])
        XCTAssertTrue(app.navigationBars["项目详情"].waitForExistence(timeout: 10))
        return nodeID(name)
    }
    private func nodeID(_ name: String) -> String {
        let field = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "project.structure.node.name.", name)).firstMatch
        reveal(field)
        return field.identifier.replacingOccurrences(of: "project.structure.node.name.", with: "")
    }
    private func verifyDetails(b: String, c: String) {
        openNodeInfo("qa-node")
        let aPredecessor = app.staticTexts["project.structure.node.predecessor.qa-node"]
        XCTAssertTrue(aPredecessor.waitForExistence(timeout: 5))
        XCTAssertEqual(aPredecessor.label, "前置节点：\(secondName)")
        closeNodeInfo("qa-node")
        openNodeInfo(c)
        let cPredecessor = app.staticTexts["project.structure.node.predecessor.\(c)"]
        XCTAssertTrue(cPredecessor.waitForExistence(timeout: 5))
        XCTAssertEqual(cPredecessor.label, "前置节点：QA 交付")
        closeNodeInfo(c)
        let first = app.textFields["project.structure.node.name.\(b)"]
        reveal(first); XCTAssertEqual(first.value as? String, secondName)
        openNodeInfo(b)
        XCTAssertTrue(app.buttons["project.structure.node.info.done.\(b)"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["project.structure.node.predecessor.\(b)"].exists)
        closeNodeInfo(b)
    }
    private func openNodeInfo(_ id: String) {
        tap(app.buttons["project.structure.node.info.\(id)"])
        XCTAssertTrue(app.buttons["project.structure.node.info.done.\(id)"].waitForExistence(timeout: 5))
    }
    private func closeNodeInfo(_ id: String) {
        let done = app.buttons["project.structure.node.info.done.\(id)"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 3))
    }
    private func checkOrder(_ ids: [String]) {
        for (i, id) in ids.enumerated() {
            let e = app.staticTexts["project.nodeOrder.name.\(id)"]
            reveal(e); XCTAssertTrue(e.label.hasPrefix("\(i + 1). "), e.label)
        }
    }
    private func waitLabel(_ id: String, _ label: String) {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: app.staticTexts[id])
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: 10), .completed)
    }
    private func openProject() {
        let tab = app.tabBars.buttons["项目"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10)); tab.tap()
        for _ in 0..<4 {
            if app.navigationBars["项目"].exists { break }
            app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        }
        tap(app.buttons["projects.project.qa-project"])
    }
    private func tap(_ e: XCUIElement) { reveal(e); e.tap() }
    private func reveal(_ e: XCUIElement) {
        func visible() -> Bool {
            guard e.exists && e.isHittable else { return false }
            let f = e.frame
            if f.minY >= 44 && f.maxY <= 112 { return true }
            let bar = app.tabBars.firstMatch
            let bottom = bar.exists && bar.isHittable ? bar.frame.minY - 6 : app.windows.firstMatch.frame.maxY - 24
            return f.minY >= 112 && f.maxY <= bottom
        }
        if e.waitForExistence(timeout: 3) && visible() { return }
        for _ in 0..<5 { app.swipeUp(); if visible() { return } }
        for _ in 0..<7 { app.swipeDown(); if visible() { return } }
        capture("unrevealed-target"); XCTFail("Cannot reveal \(e.description)")
    }
    private func record(_ name: String, _ value: String) {
        let a = XCTAttachment(string: value); a.name = "node-sequence-\(name)"; a.lifetime = .keepAlways; add(a)
    }
    private func capture(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = "node-sequence-\(name)"; a.lifetime = .keepAlways; add(a)
        record("tree-\(name)", app.debugDescription)
    }
}
