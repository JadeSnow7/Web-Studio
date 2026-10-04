import XCTest

final class Web_StudioUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }
  @MainActor
  private func launch(_ arguments: [String] = [], root: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    let rootArguments =
      (arguments.first == "--workspace-config-root" && arguments.count > 1)
      ? [] : ["--workspace-config-root", root ?? "/tmp/web-studio-ui-\(UUID().uuidString)"]
    app.launchArguments =
      [
        "-ApplePersistenceIgnoreState", "YES",
        "-NSQuitAlwaysKeepsWindows", "NO",
      ] + rootArguments + arguments
    app.launch()
    app.activate()
    let singleWindow = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "count == 1"),
      object: app.windows
    )
    XCTAssertEqual(XCTWaiter().wait(for: [singleWindow], timeout: 5), .completed)
    XCTAssertEqual(app.windows.count, 1)
    return app
  }

  private func resources(_ app: XCUIApplication) -> XCUIElementQuery {
    app.buttons.matching(NSPredicate(format: "identifier MATCHES %@", "^resource\\.[0-9A-Fa-f-]{36}$"))
  }

  @MainActor
  func testBlankLaunchVerticalResourcesAndNewTab() {
    let app = launch()
    XCTAssertTrue(app.textFields["destination.address"].waitForExistence(timeout: 5))
    XCTAssertEqual(resources(app).count, 0)
    app.typeKey("t", modifierFlags: .command)
    XCTAssertEqual(resources(app).count, 1)
    XCTAssertTrue(resources(app).firstMatch.frame.midX < app.windows.firstMatch.frame.minX + 350)
  }

  @MainActor
  func testCommandPanelsKeyboardSubmitEscapeAndClose() {
    let app = launch()
    let before = resources(app).count
    XCTAssertTrue(app.buttons["commands.button"].waitForExistence(timeout: 5))
    app.buttons["commands.button"].click()
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    app.typeKey("l", modifierFlags: .command)
    let address = app.textFields["destination.address"]
    XCTAssertTrue(address.waitForExistence(timeout: 3))
    address.typeText("example.com")
    XCTAssertTrue((address.value as? String)?.contains("example.com") == true)
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    XCTAssertTrue(address.exists)
    app.typeKey("k", modifierFlags: .command)
    let search = app.textFields["command.search"]
    XCTAssertTrue(search.waitForExistence(timeout: 3))
    search.typeText("新建网页")
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    XCTAssertEqual(resources(app).count, before + 1)
    app.typeKey("l", modifierFlags: .command)
    XCTAssertTrue(app.textFields["destination.address"].waitForExistence(timeout: 3))
    app.typeKey("w", modifierFlags: .command)
    XCTAssertEqual(resources(app).count, before + 1)
    XCTAssertTrue(app.textFields["destination.address"].exists)
  }

  @MainActor
  func testHiddenSidebarFindsResourceThroughCommandSearch() {
    let app = launch()
    app.typeKey("t", modifierFlags: .command)
    let resourceID = resources(app).firstMatch.identifier
    app.typeKey("s", modifierFlags: [.command, .option])
    app.typeKey("k", modifierFlags: .command)
    let search = app.textFields["command.search"]
    XCTAssertTrue(search.waitForExistence(timeout: 3))
    search.typeText("空白网页")
    let resourceCommand = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'command.resource.'"))
      .firstMatch
    XCTAssertTrue(resourceCommand.waitForExistence(timeout: 3))
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    XCTAssertFalse(search.exists)
    app.typeKey("s", modifierFlags: [.command, .option])
    XCTAssertTrue(app.buttons[resourceID].waitForExistence(timeout: 3))
  }

  @MainActor
  func testCommandPaletteRowsHaveDistinctBoundedGeometry() {
    let app = launch()
    app.buttons["commands.button"].click()

    let results = app.scrollViews["command.results"]
    XCTAssertTrue(results.waitForExistence(timeout: 3))
    let first = app.buttons["command.新建网页"]
    let second = app.buttons["command.新建终端"]
    XCTAssertTrue(first.waitForExistence(timeout: 3))
    XCTAssertTrue(second.waitForExistence(timeout: 3))

    let resultsFrame = results.frame
    // Accessibility frames can differ from the rendered SwiftUI container by a
    // fractional point at the edge; allow that precision boundary for containment.
    let containmentFrame = resultsFrame.insetBy(dx: -0.5, dy: -0.5)
    XCTAssertTrue(
      containmentFrame.contains(first.frame),
      "containmentFrame=\(containmentFrame.debugDescription) resultsFrame=\(resultsFrame.debugDescription) firstFrame=\(first.frame.debugDescription)"
    )
    XCTAssertTrue(
      containmentFrame.contains(second.frame),
      "containmentFrame=\(containmentFrame.debugDescription) resultsFrame=\(resultsFrame.debugDescription) secondFrame=\(second.frame.debugDescription)"
    )
    XCTAssertLessThanOrEqual(resultsFrame.height, 360)
    XCTAssertTrue(app.windows.firstMatch.frame.contains(resultsFrame))
    XCTAssertFalse(first.frame.intersects(second.frame))
    XCTAssertGreaterThan(first.frame.height, 20)
    XCTAssertGreaterThan(second.frame.minY, first.frame.minY)

    let search = app.textFields["command.search"]
    search.typeText("does not exist")
    XCTAssertTrue(app.staticTexts["没有可用命令"].waitForExistence(timeout: 3))
    app.buttons["command.search.clear"].click()
    XCTAssertTrue(first.waitForExistence(timeout: 3))
  }

  @MainActor
  func testAddressValidationKeepsInvalidInputVisible() {
    let app = launch()
    let address = app.textFields["destination.address"]
    XCTAssertTrue(address.waitForExistence(timeout: 3))
    address.typeText("ssh://-bad:70000")
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '有效'")).firstMatch.exists)
  }

  @MainActor
  func testSplitPickersAndClosePanePreserveResources() {
    let app = launch()
    app.typeKey("t", modifierFlags: .command)
    app.typeKey("t", modifierFlags: .command)
    let before = resources(app).count
    let mainWindow = app.windows.firstMatch
    XCTAssertEqual(before, 2)
    let resourceIDs = (0..<before).map { resources(app).element(boundBy: $0).identifier }
    app.descendants(matching: .any).matching(identifier: "layout.menu").firstMatch.click()
    mainWindow.menuItems["分屏"].click()
    let pickers = app.descendants(matching: .any).matching(identifier: "split.resourcePicker")
    XCTAssertGreaterThan(pickers.count, 0)
    let existingChoice = app.buttons["split.choose.\(resourceIDs[0].replacingOccurrences(of: "resource.", with: ""))"]
    XCTAssertTrue(existingChoice.waitForExistence(timeout: 3))
    existingChoice.click()
    XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "split.resourcePicker").count, 0)
    let splitPages = app.scrollViews.matching(identifier: "start.page")
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: splitPages)], timeout: 3),
      .completed)
    app.menuButtons["layout.menu"].click()
    mainWindow.menuItems["关闭聚焦窗格"].click()
    let remainingPages = app.scrollViews.matching(identifier: "start.page")
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: remainingPages)],
        timeout: 3), .completed)
    XCTAssertEqual(resources(app).count, before)
    XCTAssertEqual(
      Set((0..<resources(app).count).map { resources(app).element(boundBy: $0).identifier }), Set(resourceIDs))
  }

  @MainActor
  func testAgentBlankReadAndProviderSettingsFlow() {
    let app = launch()
    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(app.descendants(matching: .any)["agents.inspector"].waitForExistence(timeout: 3))
    app.buttons["agents.resources"].click()
    let blankRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agents.resource.'")).firstMatch
    XCTAssertTrue(blankRow.waitForExistence(timeout: 3))
    blankRow.click()
    let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已选择"), object: blankRow)
    XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 3), .completed)
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    app.buttons["agents.preview"].click()
    let read = app.buttons["agents.preview.read"]
    XCTAssertTrue(read.waitForExistence(timeout: 3))
    XCTAssertTrue(read.isEnabled)
    read.click()
    let previewError = app.descendants(matching: .any).matching(identifier: "agents.preview.error").firstMatch
    XCTAssertTrue(previewError.waitForExistence(timeout: 3))
    let errorText = previewError.label + " " + (previewError.value as? String ?? "")
    XCTAssertTrue(errorText.contains("网页不可用") || errorText.contains("资源暂时无法读取"))
    XCTAssertTrue(app.buttons["agents.preview.confirm"].exists)
    XCTAssertFalse(app.buttons["agents.preview.confirm"].isEnabled)
    XCTAssertFalse(app.buttons["agents.send"].isEnabled)
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    app.buttons["agents.provider-settings"].click()
    let model = app.textFields["provider.model"]
    XCTAssertTrue(model.waitForExistence(timeout: 3))
    let original = model.value as? String
    model.click()
    model.typeText("draft")
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    XCTAssertFalse(model.waitForExistence(timeout: 3))
    app.buttons["agents.provider-settings"].click()
    let reopenedModel = app.textFields["provider.model"]
    XCTAssertTrue(reopenedModel.waitForExistence(timeout: 3))
    XCTAssertEqual(reopenedModel.value as? String, original)
  }

  @MainActor
  func testStartPageAddsSessionPinnedDestination() {
    let app = launch()
    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(app.buttons["start.add-pin"].waitForExistence(timeout: 3))
    app.buttons["start.add-pin"].click()
    let title = app.textFields["start-entry.title"]
    let destination = app.textFields["start-entry.destination"]
    XCTAssertTrue(title.waitForExistence(timeout: 3))
    title.click()
    title.typeText("Local Preview")
    destination.click()
    destination.typeText("http://127.0.0.1:8766/")
    app.buttons["添加"].click()
    XCTAssertTrue(app.buttons["Local Preview"].waitForExistence(timeout: 3))
  }

  @MainActor
  func testAgentComposerDraftSurvivesAdvancedPanelAndNewChat() {
    let app = launch()
    let composer = app.textViews["agents.question"]
    XCTAssertTrue(composer.waitForExistence(timeout: 3))
    composer.click()
    composer.typeText("draft message")
    app.buttons["agents.resources"].click()
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    XCTAssertTrue((composer.value as? String)?.contains("draft message") == true)
    app.buttons["agents.new-question"].click()
    XCTAssertEqual(composer.value as? String, "")
    app.menuButtons["agents.question-picker"].click()
    let originalQuestion = app.menuItems.matching(NSPredicate(format: "label CONTAINS 'draft message'")).firstMatch
    XCTAssertTrue(originalQuestion.waitForExistence(timeout: 3))
    originalQuestion.click()
    XCTAssertEqual(composer.value as? String, "draft message")
  }

  @MainActor
  func testMinimumWindowLightAndDarkControls() {
    for appearance in ["--appearance-light", "--appearance-dark"] {
      let app = launch([appearance, "--minimum-window"])
      var appearancePassed = false
      addTeardownBlock { @MainActor in
        guard !appearancePassed else { return }
        let window = app.windows.firstMatch
        guard window.exists else {
          print("[diagnostic] failure window screenshot unavailable for \(appearance): main window does not exist")
          return
        }
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.lifetime = .keepAlways
        let appearanceLabel = appearance == "--appearance-light" ? "light" : "dark"
        attachment.name = "failure-window-\(appearanceLabel)"
        self.add(attachment)
      }
      XCTAssertTrue(app.textFields["destination.address"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.textFields["destination.address"].isHittable)
      XCTAssertTrue(app.buttons["commands.button"].isHittable)
      XCTAssertTrue(app.buttons["workspace.showQuestions"].waitForExistence(timeout: 3))
      XCTAssertTrue(app.buttons["workspace.showQuestions"].isHittable)
      app.buttons["workspace.showQuestions"].click()
      XCTAssertTrue(app.descendants(matching: .any)["agents.inspector"].waitForExistence(timeout: 3))
      let composer = app.textViews["agents.question"]
      XCTAssertTrue(composer.waitForExistence(timeout: 3))
      composer.click()
      composer.typeText("窄窗草稿")
      app.buttons["workspace.showContent"].click()
      XCTAssertTrue(app.textFields["destination.address"].waitForExistence(timeout: 3))
      app.buttons["workspace.showQuestions"].click()
      XCTAssertEqual(composer.value as? String, "窄窗草稿")
      let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      attachment.lifetime = .keepAlways
      attachment.name = appearance
      add(attachment)
      appearancePassed = true
      app.terminate()
    }
  }

  @MainActor
  func testSavedWorkspaceConfigurationRestoresAfterRelaunch() {
    let root = "/tmp/web-studio-ui-\(UUID().uuidString)"
    let app = launch(root: root)
    var currentApp = app
    var testPassed = false
    addTeardownBlock { @MainActor in
      guard !testPassed else { return }
      let selector = currentApp.menuButtons["workspace.selector"]
      let label = selector.exists ? selector.label : "<unavailable: workspace.selector does not exist>"
      let diagnostic = "workspace.selector actual label on failure: \(label)"
      print(diagnostic)
      let attachment = XCTAttachment(string: diagnostic)
      attachment.lifetime = .keepAlways
      attachment.name = "workspace-selector-label-on-failure"
      self.add(attachment)
    }
    XCTAssertTrue(app.textFields["destination.address"].waitForExistence(timeout: 5))
    app.typeKey("t", modifierFlags: .command)
    XCTAssertEqual(resources(app).count, 1)
    let savedIDs = Set((0..<resources(app).count).map { resources(app).element(boundBy: $0).identifier })
    app.menuButtons["workspace.selector"].click()
    app.menuItems["命名并保存…"].click()
    let workspaceName = app.textFields["空间名称"]
    XCTAssertTrue(workspaceName.waitForExistence(timeout: 3))
    workspaceName.click()
    workspaceName.typeKey("a", modifierFlags: .command)
    workspaceName.typeText("B1 UI Workspace")
    app.buttons["保存"].click()
    XCTAssertTrue(app.staticTexts["已保存"].waitForExistence(timeout: 5))
    app.terminate()
    let relaunched = launch(root: root)
    currentApp = relaunched
    XCTAssertTrue(relaunched.textFields["destination.address"].waitForExistence(timeout: 5))
    XCTAssertEqual(
      Set((0..<resources(relaunched).count).map { resources(relaunched).element(boundBy: $0).identifier }), savedIDs)
    XCTAssertTrue(relaunched.menuButtons["workspace.selector"].waitForExistence(timeout: 3))
    XCTAssertTrue(relaunched.menuButtons["workspace.selector"].label.contains("B1 UI Workspace"))
    testPassed = true
  }

  @MainActor
  func testIndependentQuestionKeepsDraftAndPickerReturnsToOriginal() {
    let app = launch()
    let composer = app.textViews["agents.question"]
    XCTAssertTrue(composer.waitForExistence(timeout: 3))
    composer.click()
    composer.typeText("first draft")
    app.buttons["agents.new-question"].click()
    XCTAssertEqual(composer.value as? String, "")
    composer.typeText("second draft")
    app.menuButtons["agents.question-picker"].click()
    let original = app.menuItems.matching(NSPredicate(format: "label CONTAINS 'first draft'")).firstMatch
    XCTAssertTrue(original.waitForExistence(timeout: 3))
    original.click()
    XCTAssertEqual(composer.value as? String, "first draft")
  }
}
