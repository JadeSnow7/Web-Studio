import XCTest

final class Web_StudioUITests: XCTestCase {
    @MainActor
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func resources(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'resource.' AND NOT identifier CONTAINS '.close.'"))
    }

    @MainActor
    func testBlankLaunchVerticalResourcesAndNewTab() {
        let app = launch()
        XCTAssertTrue(app.textFields["destination.address"].waitForExistence(timeout: 5))
        XCTAssertEqual(resources(app).count, 1)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tabs.new.'")).firstMatch.click()
        XCTAssertEqual(resources(app).count, 2)
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
        search.typeText("New Web Page")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertEqual(resources(app).count, before + 1)
        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(app.textFields["destination.address"].waitForExistence(timeout: 3))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertEqual(resources(app).count, before + 1)
        XCTAssertTrue(app.textFields["destination.address"].exists)
    }

    @MainActor
    func testCommandPaletteRowsHaveDistinctBoundedGeometry() {
        let app = launch()
        app.buttons["commands.button"].click()

        let results = app.scrollViews["command.results"]
        XCTAssertTrue(results.waitForExistence(timeout: 3))
        let first = app.buttons["command.New Web Page"]
        let second = app.buttons["command.New Terminal"]
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
        XCTAssertTrue(app.staticTexts["No available commands"].waitForExistence(timeout: 3))
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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'valid SSH'" )).firstMatch.exists)
    }

    @MainActor
    func testSplitPickersAndClosePanePreserveResources() {
        let app = launch()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tabs.new.'")).firstMatch.click()
        let before = resources(app).count
        app.descendants(matching: .any).matching(identifier: "layout.menu").firstMatch.click()
        app.menuItems["Split"].click()
        let pickers = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'pane.resource-picker.'"))
        XCTAssertEqual(pickers.count, 0)
        app.descendants(matching: .any).matching(identifier: "layout.menu").firstMatch.click()
        app.menuItems["Close Focused Pane"].click()
        XCTAssertEqual(resources(app).count, before)
        app.typeKey("s", modifierFlags: [.command, .option])
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["command.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.typeText("Select New Tab")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertFalse(search.exists)
        app.typeKey("s", modifierFlags: [.command, .option])
        XCTAssertEqual(resources(app).count, before)
    }

    @MainActor
    func testAgentBlankReadAndProviderSettingsFlow() {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["agents.inspector"].waitForExistence(timeout: 3))
        app.buttons["agents.resources"].click()
        let blankRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agents.resource.'")).firstMatch
        XCTAssertTrue(blankRow.waitForExistence(timeout: 3))
        blankRow.click()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已选择"), object: blankRow)
        XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 3), .completed)
        app.buttons["agents.preview"].click()
        let read = app.buttons["agents.preview.read"]
        XCTAssertTrue(read.waitForExistence(timeout: 3))
        XCTAssertTrue(read.isEnabled)
        read.click()
        let previewError = app.descendants(matching: .any).matching(identifier: "agents.preview.error").firstMatch
        XCTAssertTrue(previewError.waitForExistence(timeout: 3))
        let errorText = previewError.label + " " + (previewError.value as? String ?? "")
        XCTAssertTrue(errorText.contains("Page is unavailable.") || errorText.contains("Resource is not readable yet."))
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
        app.buttons["agents.new-chat"].click()
        XCTAssertEqual(composer.value as? String, "")
    }

    @MainActor
    func testMinimumWindowLightAndDarkControls() {
        for appearance in ["--appearance-light", "--appearance-dark"] {
            let app = launch([appearance, "--minimum-window"])
            XCTAssertTrue(app.textFields["destination.address"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.textFields["destination.address"].isHittable)
            XCTAssertTrue(app.buttons["commands.button"].isHittable)
            XCTAssertTrue(app.descendants(matching: .any)["agents.inspector"].waitForExistence(timeout: 3))
            app.typeKey("a", modifierFlags: [.command, .option])
            XCTAssertFalse(app.descendants(matching: .any)["agents.inspector"].waitForExistence(timeout: 1))
            app.typeKey("a", modifierFlags: [.command, .option])
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.lifetime = .keepAlways
            attachment.name = appearance
            add(attachment)
            app.terminate()
        }
    }
}
