import Foundation
import Testing
import AppKit
import WebKit
@testable import Web_Studio

private final class TestFirstResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

struct Web_StudioTests {
    @Test @MainActor func bareDomainNormalizesToHTTPS() {
        #expect(
            StudioModel.normalizedWebURL("example.com")?
                .absoluteString == "https://example.com"
        )
        #expect(StudioModel.normalizedWebURL("ftp://example.com") == nil)
    }

    @Test @MainActor func sshDefaultsPortAndRejectsInvalidValues() {
        #expect(
            StudioModel.normalizedSSH(host: "server.example", user: "dev", portText: "")
                == .ssh(host: "server.example", user: "dev", port: 22)
        )
        #expect(
            StudioModel
                .normalizedSSH(host: "server.example", user: "", portText: "70000") == nil
        )
        #expect(StudioModel.normalizedSSH(host: "server.example", user: "", portText: "abc") == nil)
    }

    @Test @MainActor func closingLastTabReturnsToBlankTab() {
        let model = StudioModel(launchTerminalProcesses: false)
        model.setDestination(.ssh(host: "host", user: "", port: 22))
        model.closeSelectedTab()
        #expect(model.tabs.count == 1)
        #expect(model.selectedTab?.destination == .blank)
    }

    @Test @MainActor func closingInactiveTabPreservesSelection() {
        let model = StudioModel(launchTerminalProcesses: false)
        let first = model.selectedTabID
        model.newTab()
        let selected = model.selectedTabID
        model.close(tabID: first)
        #expect(model.selectedTabID == selected)
    }

    @Test @MainActor func taskGroupsKeepSelectionAndMoveActiveTab() {
        let model = StudioModel(launchTerminalProcesses: false)
        let firstGroup = model.selectedGroupID
        model.addGroup()
        let secondGroup = model.selectedGroupID
        let movedTab = model.selectedTabID
        #expect(model.selectedTab?.groupID == secondGroup)
        model.move(tabID: movedTab, to: firstGroup)
        #expect(model.selectedGroupID == firstGroup)
        #expect(model.selectedTabID == movedTab)
        #expect(model.visibleTabs.contains { $0.id == movedTab })
    }

    @Test @MainActor func movingInactiveTabDoesNotChangeCurrentSelection() {
        let model = StudioModel(launchTerminalProcesses: false)
        let firstTab = model.selectedTabID
        model.newTab()
        let activeTab = model.selectedTabID
        let otherGroup = StudioGroup(name: "Other")
        model.groups.append(otherGroup)
        model.move(tabID: firstTab, to: otherGroup.id)
        #expect(model.selectedTabID == activeTab)
    }

    @Test @MainActor func selectingEmptyGroupCreatesItsBlankTab() {
        let model = StudioModel(launchTerminalProcesses: false)
        let group = StudioGroup(name: "Empty")
        model.groups.append(group)
        model.selectGroup(group.id)
        #expect(model.selectedGroupID == group.id)
        #expect(model.selectedTab?.groupID == group.id)
        #expect(model.selectedTab?.destination == .blank)
    }

    @Test @MainActor func workspaceActionsTargetTheirOwningGroup() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        let group = StudioGroup(name: "Inactive")
        model.groups.append(group)
        let originalGroup = model.groups[0].id
        model.newTab(in: group.id)
        #expect(model.selectedGroupID == group.id)
        #expect(model.selectedTab?.groupID == group.id)
        model.newTerminal(in: originalGroup, directory: "/tmp")
        let terminal = try #require(model.selectedTab)
        #expect(terminal.groupID == originalGroup)
        #expect(model.tabs.filter { $0.groupID == group.id }.count == 1)
    }

    @Test @MainActor func closingActiveTabPrefersAnotherTabInSameGroup() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        model.newTab()
        let active = model.selectedTabID
        let sameGroupTab = try #require(model.tabs.first { $0.id != active })
        model.close(tabID: active)
        #expect(model.selectedTabID == sameGroupTab.id)
        #expect(model.selectedGroupID == sameGroupTab.groupID)
    }

    @Test func layoutResolverCompactsAndProtectsMainWidth() {
        let plan = StudioLayoutPlan.resolve(
            windowWidth: 900,
            sidebarWidth: 220,
            agentsWidth: 300,
            sidebarVisible: true,
            agentsVisible: true
        )
        #expect(plan.compactSidebar)
        #expect(plan.sidebarWidth == 96)
        #expect(900 - plan.sidebarWidth - plan.agentsWidth >= 440)
        #expect(plan.adaptationMessage != nil)
    }

    @Test @MainActor func modalOpenersRemainMutuallyExclusive() {
        let model = StudioModel(launchTerminalProcesses: false)
        model.openCommands()
        #expect(model.commandPalettePresented)
        #expect(!model.destinationPresented)
        model.openDestination()
        #expect(!model.destinationPresented)
        #expect(!model.commandPalettePresented)
        model.openGroupEditor()
        #expect(model.groupEditorPresented)
        #expect(!model.destinationPresented)
    }

    @Test @MainActor func nonDefaultSSHPortAppearsInTabTitleAndWebPathIsSeparate() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        model.setDestination(.ssh(host: "server.example", user: "dev", port: 2222))
        #expect(model.selectedTab?.destination.title == "dev@server.example:2222")
        try model.setDestination(.web(#require(URL(string: "https://example.com/docs?q=swift"))))
        #expect(model.selectedTab?.destination.title == "example.com")
        #expect(model.selectedTab?.destination.detail == "/docs?q=swift")
        try model.setDestination(.web(#require(URL(string: "http://example.com:8080/docs#intro"))))
        #expect(model.selectedTab?.destination.title == "example.com:8080")
        #expect(model.selectedTab?.destination.detail == "/docs#intro")
    }

    @Test @MainActor func addressParserRoutesWebSSHAndLocalTerminalInputs() throws {
        let localhost = try #require(URL(string: "https://localhost:8080"))
        #expect(StudioModel.parseAddress("localhost:8080") == .web(localhost))
        #expect(StudioModel.parseAddress("ssh://dev@[::1]:2222") == .ssh(host: "::1", user: "dev", port: 2222))
        #expect(StudioModel.parseAddress("dev@example.com:2200") == .ssh(host: "example.com", user: "dev", port: 2200))
        #expect(StudioModel.parseAddress("terminal:///tmp") == .terminal(directory: "/tmp"))
        #expect(StudioModel.parseAddress("terminal://~/Projects") == .terminal(directory: NSHomeDirectory() + "/Projects"))
    }

    @Test @MainActor func addressParserRejectsUnsupportedOrMalformedInputs() {
        #expect(StudioModel.parseAddress("javascript:alert(1)") == nil)
        #expect(StudioModel.parseAddress("ssh://user:password@example.com") == nil)
        #expect(StudioModel.parseAddress("ssh://[::1]junk") == nil)
        #expect(StudioModel.parseAddress("terminal://relative/path") == .terminal(directory: NSHomeDirectory() + "/relative/path"))
    }

    @Test @MainActor func addressFieldTracksIdleTabSelectionAndPreservesSourceSession() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        let source = model.selectedTabID
        try model.setDestination(.web(#require(URL(string: "https://example.com"))))
        let runtime = model.webRuntimes.existingRuntime(for: source)
        model.newTab()
        #expect(model.addressText.isEmpty)
        model.selectResource(source)
        #expect(model.addressText == "https://example.com")
        #expect(model.webRuntimes.existingRuntime(for: source) === runtime)
    }

    @Test @MainActor func addressFieldAllowsSecondSubmissionWithoutResettingDraft() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        model.requestAddressFocus()
        model.addressText = "https://example.com/one"
        model.noteAddressEdit()
        model.submitAddress()
        model.addressText = "https://example.com/two"
        model.noteAddressEdit()
        model.submitAddress()
        #expect(model.selectedTab?.destination.detail == "/two")
    }

    // MARK: Web runtime

    @Test @MainActor func webRuntimeIsCreatedOncePerTabAndKeepsItsWebView() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        try model.setDestination(.web(#require(URL(string: "https://example.com"))))
        let first = model.webRuntimes.runtime(for: model.selectedTabID)!
        let second = model.webRuntimes.runtime(for: model.selectedTabID)!
        #expect(first === second)
        #expect(first.webView === second.webView)
        #expect(model.webRuntimes.activeRuntimeCount == 1)
        #expect(model.activeWebRuntime === first)
    }

    @Test @MainActor func closingAWebTabReleasesItsRuntime() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        try model.setDestination(.web(#require(URL(string: "https://example.com"))))
        let webTab = model.selectedTabID
        _ = model.webRuntimes.runtime(for: webTab)
        model.newTab()
        model.close(tabID: webTab)
        #expect(model.webRuntimes.activeRuntimeCount == 0)
        #expect(model.webRuntimes.existingRuntime(for: webTab) == nil)
    }

    @Test @MainActor func openingSSHFromWebKeepsWebResourceAndCreatesSibling() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        try model.setDestination(.web(#require(URL(string: "https://example.com"))))
        let webTab = model.selectedTabID
        _ = model.webRuntimes.runtime(for: webTab)
        #expect(model.webRuntimes.activeRuntimeCount == 1)
        model.setDestination(.ssh(host: "server.example", user: "", port: 22))
        #expect(model.webRuntimes.activeRuntimeCount == 1)
        #expect(model.selectedTabID != webTab)
        #expect(model.webRuntimes.records[webTab]?.kind == .web)
        #expect(!model.selectedTabIsWeb)
    }

    @Test @MainActor func panelCoordinatorCapturesTargetAndReportsClosedResource() {
        let store = ResourceStore(launchTerminalProcesses: false)
        let groupID = UUID()
        let resourceID = store.registerWeb(groupID: groupID)
        let coordinator = PanelCoordinator()
        coordinator.open(.destination, targetResourceID: resourceID, originalResponder: nil, store: store)
        #expect(coordinator.targetResourceID == resourceID)
        store.remove(resourceID: resourceID)
        coordinator.markTargetClosed()
        #expect(coordinator.errorMessage != nil)
    }

    @Test @MainActor func committedNavigationFollowsTheLivePageOnWebTabsOnly() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        try model.setDestination(.web(#require(URL(string: "https://example.com"))))
        let webTab = model.selectedTabID
        try model.updateWebDestination(
            tabID: webTab,
            url: #require(URL(string: "https://docs.example.com/guide"))
        )
        #expect(model.selectedTab?.destination.title == "docs.example.com")
        #expect(model.selectedTab?.destination.detail == "/guide")

        model.setDestination(.ssh(host: "server.example", user: "", port: 22))
        try model.updateWebDestination(
            tabID: webTab,
            url: #require(URL(string: "https://other.example.com"))
        )
        #expect(model.selectedTab?.destination == .ssh(host: "server.example", user: "", port: 22))
    }

    @Test @MainActor func popupNavigationOpensASiblingTabInTheSameTask() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        let task = model.selectedGroupID
        let opener = model.selectedTabID
        try model.openWebTab(#require(URL(string: "https://example.com/popup")))
        #expect(model.selectedTabID != opener)
        #expect(model.selectedTab?.groupID == task)
        #expect(model.selectedTab?.destination.title == "example.com")
        #expect(model.visibleTabs.count == 2)
    }

    @Test @MainActor func activeWebStateResetsWhenSelectionLeavesTheWebTab() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        try model.setDestination(.web(#require(URL(string: "https://example.com"))))
        _ = model.webRuntimes.runtime(for: model.selectedTabID)
        model.recordWebState(tabID: model.selectedTabID, state: WebNavigationState(isLoading: true, canGoBack: true))
        model.newTab()
        #expect(!model.selectedTabIsWeb)
        #expect(model.activeWebState == WebNavigationState())
        #expect(model.activeWebRuntime == nil)
    }

    @Test @MainActor func webCommandsAreInertWithoutAWebRuntime() {
        let model = StudioModel(launchTerminalProcesses: false)
        #expect(!model.selectedTabIsWeb)
        model.webGoBack()
        model.webGoForward()
        model.webReloadOrStop()
        #expect(model.activeWebState == WebNavigationState())
        #expect(model.webRuntimes.activeRuntimeCount == 0)
    }

    @Test func navigationPolicyRendersWebAndHandsOffOnlyClickedAppSchemes() throws {
        let page = try #require(URL(string: "https://example.com/a"))
        #expect(WebTabRuntime.route(for: page, isLinkActivation: false) == .allow)
        let blank = try #require(URL(string: "about:blank"))
        #expect(WebTabRuntime.route(for: blank, isLinkActivation: false) == .allow)

        let mail = try #require(URL(string: "mailto:dev@example.com"))
        #expect(WebTabRuntime.route(for: mail, isLinkActivation: true) == .openExternally)
        // Same scheme without a click is a page-driven app launch, so it is refused.
        #expect(WebTabRuntime.route(for: mail, isLinkActivation: false) == .cancel)

        let unknown = try #require(URL(string: "custom-app://run"))
        #expect(WebTabRuntime.route(for: unknown, isLinkActivation: true) == .cancel)
        let file = try #require(URL(string: "file:///etc/passwd"))
        #expect(WebTabRuntime.route(for: file, isLinkActivation: true) == .cancel)
    }

    @Test func cancelledAndInterruptedLoadsAreNotReportedAsFailures() throws {
        let url = try #require(URL(string: "https://example.com"))
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        #expect(WebTabRuntime.failure(for: cancelled, url: url) == nil)
        let interrupted = NSError(domain: "WebKitErrorDomain", code: 102)
        #expect(WebTabRuntime.failure(for: interrupted, url: url) == nil)

        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let failure = try #require(WebTabRuntime.failure(for: offline, url: url))
        #expect(failure.url == url)
        #expect(!failure.message.isEmpty)
    }

    // MARK: Shared commands and tab keyboard access

    @Test @MainActor func commandPaletteListsPageCommandsOnlyWhenTheyCanRun() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        var titles: Set<String> { Set(model.availableCommands.map(\.title)) }

        #expect(titles.contains("New Web Page"))
        #expect(!titles.contains("Back"))
        #expect(!titles.contains("Reload Page"))

        try model.setDestination(.web(#require(URL(string: "https://example.com"))))
        #expect(titles.contains("Reload Page"))
        #expect(!titles.contains("Back"))

        model.recordWebState(tabID: model.selectedTabID, state: WebNavigationState(canGoBack: true, canGoForward: true))
        #expect(titles.contains("Back"))
        #expect(titles.contains("Forward"))

        model.recordWebState(tabID: model.selectedTabID, state: WebNavigationState(isLoading: true))
        #expect(titles.contains("Stop Loading"))
        #expect(!titles.contains("Reload Page"))
    }

    @Test @MainActor func tabCyclingCommandsAppearOnlyWithMoreThanOneTab() {
        let model = StudioModel(launchTerminalProcesses: false)
        #expect(!model.availableCommands.contains { $0.title == "Show Next Tab" })
        model.newTab()
        #expect(model.availableCommands.contains { $0.title == "Show Next Tab" })
        #expect(model.availableCommands.contains { $0.title == "Show Previous Tab" })
    }

    @Test @MainActor func selectingTabByNumberMatchesSafariNumbering() {
        let model = StudioModel(launchTerminalProcesses: false)
        let first = model.selectedTabID
        model.newTab()
        let second = model.selectedTabID
        model.newTab()
        let third = model.selectedTabID

        model.selectTab(at: 0)
        #expect(model.selectedTabID == first)
        model.selectTab(at: 1)
        #expect(model.selectedTabID == second)
        // ⌘9 is the last tab however many are open.
        model.selectTab(at: 8)
        #expect(model.selectedTabID == third)
        // A position with no tab leaves the selection alone.
        model.selectTab(at: 5)
        #expect(model.selectedTabID == third)
    }

    @Test @MainActor func tabCyclingWrapsWithinTheSelectedTask() {
        let model = StudioModel(launchTerminalProcesses: false)
        let first = model.selectedTabID
        model.newTab()
        let second = model.selectedTabID
        model.selectNextTab()
        #expect(model.selectedTabID == first)
        model.selectPreviousTab()
        #expect(model.selectedTabID == second)
    }

    @Test @MainActor func tabTitleFollowsPageTitleAndFallsBackToDestination() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        #expect(model.selectedTab?.displayTitle == "New Tab")

        try model.setDestination(.web(#require(URL(string: "https://example.com/docs"))))
        #expect(model.selectedTab?.displayTitle == "example.com")

        model.recordWebState(
            tabID: model.selectedTabID,
            state: WebNavigationState(pageTitle: "Example Domain")
        )
        #expect(model.selectedTab?.displayTitle == "Example Domain")
        // The address stays the accessible identity behind the page title.
        #expect(model.selectedTab?.destination.accessibilityTitle == "https://example.com/docs")

        model.setDestination(.ssh(host: "server.example", user: "", port: 22))
        #expect(model.selectedTab?.displayTitle == "server.example")
    }

    @Test @MainActor func backgroundTabTitleUpdatesWithoutTouchingTheToolbar() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        try model.setDestination(.web(#require(URL(string: "https://example.com"))))
        let background = model.selectedTabID
        model.newTab()

        model.recordWebState(
            tabID: background,
            state: WebNavigationState(pageTitle: "Example Domain", canGoBack: true)
        )
        #expect(model.tabs.first { $0.id == background }?.displayTitle == "Example Domain")
        #expect(model.activeWebState == WebNavigationState())
    }

    @Test @MainActor func resourceStoreKeepsStableIDsAndOwnsWebRuntime() throws {
        let groupID = UUID()
        let store = ResourceStore(launchTerminalProcesses: false)
        let resourceID = store.registerWeb(groupID: groupID)
        #expect(store.records[resourceID]?.kind == .web)
        #expect(store.records[resourceID]?.groupID == groupID)
        let runtime = store.runtime(for: resourceID)!
        #expect(store.existingRuntime(for: resourceID) === runtime)
        #expect(store.runtime(for: resourceID) === runtime)
        store.remove(resourceID: resourceID)
        #expect(store.records[resourceID] == nil)
        #expect(store.existingRuntime(for: resourceID) == nil)
    }

    @Test @MainActor func closingLastTabCreatesANewResourceID() {
        let model = StudioModel(launchTerminalProcesses: false)
        let oldID = model.selectedTabID
        model.closeSelectedTab()
        #expect(model.tabs.count == 1)
        #expect(model.selectedTabID != oldID)
        #expect(model.webRuntimes.records[oldID] == nil)
        #expect(model.webRuntimes.records[model.selectedTabID]?.kind == .web)
    }

    @Test @MainActor func closingSelectedTabWithTwoTabsSelectsRemainingResource() {
        let model = StudioModel(launchTerminalProcesses: false)
        let first = model.selectedTabID
        model.newTab()
        let second = model.selectedTabID
        model.close(tabID: second)
        #expect(model.selectedTabID == first)
        #expect(model.webRuntimes.records[first] != nil)
    }

    @Test @MainActor func pruningWebRuntimesDoesNotDeleteNonWebRecords() {
        let model = StudioModel(launchTerminalProcesses: false)
        model.setDestination(.ssh(host: "server.example", user: "dev", port: 22))
        let id = model.selectedTabID
        model.pruneWebRuntimes()
        #expect(model.webRuntimes.records[id]?.kind == .sshTerminal)
        #expect(model.webRuntimes.order.contains(id))
    }

    @Test @MainActor func sshRejectsControlCharactersAndOptionInjection() {
        #expect(StudioModel.normalizedSSH(host: "server\u{0000}.example", user: "", portText: "") == nil)
        #expect(StudioModel.normalizedSSH(host: "-oProxyCommand=bad", user: "", portText: "") == nil)
        #expect(StudioModel.normalizedSSH(host: "server.example", user: "-o", portText: "") == nil)
        #expect(StudioModel.normalizedSSH(host: "server.example", user: "build-user", portText: "") == .ssh(host: "server.example", user: "build-user", port: 22))
        #expect(StudioModel.normalizedSSH(host: "server..example", user: "", portText: "") == nil)
        #expect(StudioModel.normalizedSSH(host: "-server.example", user: "", portText: "") == nil)
        #expect(StudioModel.normalizedSSH(host: "256.1.1.1", user: "", portText: "") == nil)
        #expect(StudioModel.normalizedSSH(host: "2001:db8::1", user: "", portText: "") == .ssh(host: "2001:db8::1", user: "", port: 22))
    }

    @Test @MainActor func capturedPaneNewTabReplacesOnlyCapturedPane() {
        let model = StudioModel(launchTerminalProcesses: false)
        let primary = model.selectedTabID
        model.split()
        guard let secondary = model.layout.secondary?.resourceID else { Issue.record("expected split"); return }
        let capturedPane = model.layout.primary.id
        model.openCommands()
        model.focusPane(model.layout.secondary!.id)
        let command = StudioCommand(title: "New Web Page", shortcut: "⌘T", targetResourceID: primary, action: .newTab(groupID: model.selectedGroupID))
        #expect(model.execute(command))
        #expect(model.layout.primary.resourceID != primary)
        #expect(model.layout.primary.id == capturedPane)
        #expect(model.layout.secondary?.resourceID == secondary)
        #expect(model.webRuntimes.records[primary] != nil)
        #expect(model.webRuntimes.records[secondary] != nil)
        #expect(model.webRuntimes.records[model.layout.primary.resourceID!] != nil)
    }

    @Test @MainActor func shutdownAwaitsRemovedResourcesAndIsIdempotent() async {
        let store = ResourceStore(launchTerminalProcesses: false)
        _ = store.registerWeb(groupID: UUID(), destination: nil)
        let terminalID = store.registerLocalTerminal(groupID: UUID(), directory: "/tmp")
        _ = store.runtime(for: store.order[0])
        store.remove(resourceID: terminalID)
        async let first: Void = store.shutdown()
        async let second: Void = store.shutdown()
        _ = await (first, second)
        #expect(store.records.isEmpty)
        #expect(store.activeRuntimeCount == 0)
    }

    @Test @MainActor func storeShutdownIsScopedAndCallbackRunsOnce() async {
        let storeA = ResourceStore(launchTerminalProcesses: false)
        let storeB = ResourceStore(launchTerminalProcesses: false)
        _ = storeA.registerWeb(groupID: UUID())
        _ = storeB.registerWeb(groupID: UUID())
        var callbackCount = 0
        storeA.onShutdown = { callbackCount += 1 }
        async let first: Void = storeA.shutdown()
        async let second: Void = storeA.shutdown()
        _ = await (first, second)
        #expect(callbackCount == 1)
        #expect(storeA.records.isEmpty)
        #expect(storeB.records.isEmpty == false)
    }

    @Test @MainActor func windowCloseShutsDownWebOnlyStore() async {
        let model = StudioModel(launchTerminalProcesses: false)
        var callbackCount = 0
        model.webRuntimes.onShutdown = { callbackCount += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let proxy = WindowDelegateProxy(original: nil, model: model)
        window.delegate = proxy
        #expect(proxy.windowShouldClose(window) == false)
        for _ in 0..<20 where !model.webRuntimes.records.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.webRuntimes.records.isEmpty)
        #expect(callbackCount == 1)
        window.delegate = nil
    }

    @Test @MainActor func panelCloseRestoresCapturedWindowAndUsesFallback() {
        let store = ResourceStore(launchTerminalProcesses: false)
        let resourceID = store.registerWeb(groupID: UUID())
        let windowA = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let windowB = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        windowA.isReleasedWhenClosed = false; windowB.isReleasedWhenClosed = false
        let responder = TestFirstResponderView(frame: .zero); responder.wantsLayer = true
        windowA.contentView = responder
        #expect(windowA.makeFirstResponder(responder))
        let coordinator = PanelCoordinator()
        coordinator.openDestination(targetResourceID: resourceID, originalResponder: responder, store: store)
        #expect(windowA.makeFirstResponder(nil))
        var fallbackCalled = false
        coordinator.close(window: windowB, fallback: { fallbackCalled = true })
        #expect(windowA.firstResponder === responder)
        #expect(windowB.firstResponder !== responder)
        #expect(!fallbackCalled)
        windowA.contentView = responder
        coordinator.openDestination(targetResourceID: resourceID, originalResponder: responder, store: store)
        let detached = NSView(frame: .zero)
        windowA.contentView = detached
        coordinator.close(window: windowA, fallback: { fallbackCalled = true })
        #expect(fallbackCalled)
        windowA.delegate = nil; windowB.delegate = nil
    }

    @Test @MainActor func sshExit255MapsToInterruptedAndUnknownResourceIsIgnored() {
        let store = ResourceStore(launchTerminalProcesses: false)
        let sshID = store.registerSSH(groupID: UUID(), host: "example.com", user: "dev", port: 22)
        store.recordTerminalState(resourceID: sshID, state: .exited(255))
        #expect(store.records[sshID]?.lifecycle == .interrupted)
        #expect(store.records[sshID]?.errorMessage?.contains("exit 255") == true)
        let localID = store.registerLocalTerminal(groupID: UUID(), directory: "/tmp")
        store.recordTerminalState(resourceID: localID, state: .exited(255))
        #expect(store.records[localID]?.lifecycle == .exited)
        store.recordTerminalState(resourceID: sshID, state: .running)
        #expect(store.records[sshID]?.lifecycle == .running)
        #expect(store.records[sshID]?.errorMessage == nil)
        let before = store.records
        store.recordTerminalState(resourceID: UUID(), state: .running)
        #expect(store.records == before)
    }

    @Test @MainActor func splitSupportsAllResourceKindsWithoutDuplicateMounts() {
        let model = StudioModel(launchTerminalProcesses: false)
        let web = model.selectedTabID
        let local = model.webRuntimes.registerLocalTerminal(groupID: model.selectedGroupID, directory: "/tmp")
        let ssh = model.webRuntimes.registerSSH(groupID: model.selectedGroupID, host: "example.com", user: "dev", port: 22)
        model.split(resourceID: local)
        #expect(model.layout.secondary?.resourceID == local)
        model.returnToSinglePane(); model.split(resourceID: ssh)
        #expect(model.layout.secondary?.resourceID == ssh)
        #expect(web != local && local != ssh)
        model.returnToSinglePane(); model.split(resourceID: web)
        #expect(model.layout.secondary == nil)
    }

    @Test @MainActor func layoutRejectsUnknownPaneAndResourceAndPreservesSwapIdentity() {
        let model = StudioModel(launchTerminalProcesses: false)
        let first = model.selectedTabID
        model.split()
        guard let secondary = model.layout.secondary else { Issue.record("expected split"); return }
        let firstPaneID = model.layout.primary.id
        model.focusPane(UUID())
        #expect(model.layout.primary.isFocused)
        model.swapPanes()
        #expect(model.layout.primary.id == secondary.id)
        #expect(model.layout.secondary?.id == firstPaneID)
        #expect(model.layout.primary.resourceID == secondary.resourceID)
        model.split(resourceID: UUID())
        #expect(model.layout.secondary?.resourceID == first)
    }

    @Test @MainActor func closePanePreservesResourceAndCloseResourcePrunesLayout() {
        let model = StudioModel(launchTerminalProcesses: false)
        model.split()
        guard let secondaryID = model.layout.secondary?.resourceID, let secondaryPane = model.layout.secondary else { Issue.record("expected split"); return }
        model.closePane(secondaryPane.id)
        #expect(model.webRuntimes.records[secondaryID] != nil)
        model.split(resourceID: secondaryID)
        model.close(tabID: secondaryID)
        #expect(model.layout.primary.resourceID != secondaryID)
        #expect(model.layout.secondary?.resourceID != secondaryID)
    }

    @Test @MainActor func splitRatioIsClamped() {
        let model = StudioModel(launchTerminalProcesses: false)
        model.split(); model.setSplitRatio(0.01); #expect(model.layout.splitRatio == 0.2)
        model.setSplitRatio(2); #expect(model.layout.splitRatio == 0.8)
    }

    @Test @MainActor func splitSupportsWebWebAndTerminalTerminal() {
        let model = StudioModel(launchTerminalProcesses: false)
        let web2 = model.webRuntimes.registerWeb(groupID: model.selectedGroupID)
        model.split(resourceID: web2); #expect(model.layout.secondary?.resourceID == web2)
        model.returnToSinglePane()
        let terminal1 = model.webRuntimes.registerLocalTerminal(groupID: model.selectedGroupID, directory: "/tmp")
        let terminal2 = model.webRuntimes.registerLocalTerminal(groupID: model.selectedGroupID, directory: "/tmp")
        model.selectResource(terminal1); model.split(resourceID: terminal2)
        #expect(model.layout.secondary?.resourceID == terminal2)
    }

    @Test @MainActor func panelKeepsCapturedPaneWhenSelectionChanges() {
        let model = StudioModel(launchTerminalProcesses: false)
        let captured = model.selectedTabID
        model.beginAddressEditing()
        model.newTab()
        #expect(model.addressText.isEmpty)
        model.webRuntimes.remove(resourceID: captured)
        model.setDestination(.web(URL(string: "https://example.com")!), targetResourceID: captured)
        #expect(model.addressError?.contains("closed") == true)
    }

    @Test @MainActor func nativeResourceHostReplacesOnlyOwnedView() {
        let host = NativeResourceContainer()
        let first = NSView(); let second = NSView()
        host.mount(first)
        #expect(first.superview === host)
        host.mount(second)
        #expect(first.superview == nil)
        #expect(second.superview === host)
        host.mount(first)
        #expect(second.superview == nil)
        #expect(first.superview === host)
        host.unmount()
        #expect(first.superview == nil)
    }

    @Test @MainActor func capturedDestinationRejectsClosedResource() {
        let model = StudioModel(launchTerminalProcesses: false)
        let captured = model.selectedTabID
        model.beginAddressEditing()
        model.addressText = "https://example.com"
        model.noteAddressEdit()
        model.webRuntimes.remove(resourceID: captured)
        model.submitAddress()
        #expect(model.addressError?.contains("closed") == true)
    }

    @Test @MainActor func closedCapturedPaneRejectsActionWhileResourceSurvives() {
        let model = StudioModel(launchTerminalProcesses: false)
        let resource = model.selectedTabID
        model.split()
        let pane = model.focusedPane.id
        model.beginAddressEditing()
        model.addressText = "https://example.com"
        model.noteAddressEdit()
        model.closePane(pane)
        model.submitAddress()
        #expect(model.addressError?.contains("pane") == true)
    }

    @Test @MainActor func reparentedNativeViewSurvivesOldHostUnmount() {
        let firstHost = NativeResourceContainer()
        let secondHost = NativeResourceContainer()
        let view = NSView()
        firstHost.mount(view)
        secondHost.mount(view)
        firstHost.unmount()
        #expect(view.superview === secondHost)
    }

    @Test @MainActor func blankTabsDoNotConsumeRecentSlots() {
        let model = StudioModel(launchTerminalProcesses: false)
        model.selectResource(model.selectedTabID)
        model.newTab()
        model.newTab()
        #expect(model.recentResourceIDs.isEmpty)
    }

    @Test @MainActor func explicitWebDestinationAddsRecentResource() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        let id = model.selectedTabID
        model.setDestination(.web(try #require(URL(string: "https://example.com"))), targetResourceID: id)
        #expect(model.recentResourceIDs.first == id)
    }

    @Test @MainActor func pinnedWebDestinationSurvivesSourceCloseAndReusesBlank() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        let source = model.webRuntimes.registerWeb(groupID: model.selectedGroupID, destination: try #require(URL(string: "https://example.com")))
        model.pinDestination(for: source)
        let entry = try #require(model.pinnedDestinations.first)
        model.webRuntimes.remove(resourceID: source)
        let blank = model.webRuntimes.registerWeb(groupID: model.selectedGroupID)
        model.selectResource(blank)
        let count = model.webRuntimes.resources.count
        model.openPinnedDestination(entry, from: blank)
        #expect(model.webRuntimes.resources.count == count)
        guard let record = model.webRuntimes.records[blank] else { Issue.record("blank resource missing"); return }
        guard case let .web(url) = record.location else { Issue.record("blank resource changed kind"); return }
        #expect(url?.host == "example.com")
    }

    @Test @MainActor func duplicatePinnedDestinationUpdatesLabel() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        let destination = StudioDestination.web(try #require(URL(string: "https://example.com")))
        model.addPinnedDestination(title: "First", destination: destination)
        model.addPinnedDestination(title: "Renamed", destination: destination)
        #expect(model.pinnedDestinations.count == 1)
        #expect(model.pinnedDestinations.first?.title == "Renamed")
    }

    @Test @MainActor func pinnedTerminalFromSecondaryPaneUsesSourceGroupAndPane() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        let secondaryGroup = StudioGroup(name: "Secondary")
        model.groups.append(secondaryGroup)
        let primaryGroupID = model.selectedGroupID
        let secondary = model.webRuntimes.registerWeb(groupID: secondaryGroup.id)
        model.split(resourceID: secondary)
        let sourcePane = try #require(model.layout.secondary?.id)
        let entry = PinnedDestination(title: "Tools", destination: .terminal(directory: "/tmp/tools"))
        model.openPinnedDestination(entry, from: secondary)
        let created = try #require(model.layout.secondary?.resourceID)
        #expect(model.layout.secondary?.id == sourcePane)
        #expect(model.webRuntimes.records[created]?.groupID == secondaryGroup.id)
        #expect(primaryGroupID != secondaryGroup.id)
        #expect(model.webRuntimes.records[created]?.kind == .localTerminal)
    }

}
