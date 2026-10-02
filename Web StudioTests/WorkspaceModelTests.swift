import Combine
import Foundation
import Testing
@testable import Web_Studio

@MainActor
struct WorkspaceModelTests {
    @Test func emptyWorkspaceSupportsAddressAndCommandCreation() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        model.openCommands()
        let command = try #require(model.availableCommands.first { $0.title == "新建网页" })
        #expect(model.execute(command))
        #expect(model.tabs.count == 1)
        model.dismissPanel()
        model.closeSelectedTab()
        model.beginAddressEditing()
        model.addressText = "example.test"
        model.submitAddress()
        #expect(model.selectedTab?.destination == .web(URL(string: "https://example.test")!))
        #expect(model.tabs.count == 1)
    }

    @Test func switchesPreserveRuntimeLayoutDraftAndPins() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        #expect(model.tabs.isEmpty)
        let a = model.session
        model.newTab()
        let web = model.selectedTabID
        model.setDestination(.web(URL(string: "https://example.test/a")!))
        model.newTerminal(directory: "/tmp")
        let terminal = model.selectedTabID
        let terminalSession = try #require(model.webRuntimes.terminalSession(for: terminal))
        model.selectResource(web)
        model.split(resourceID: terminal)
        model.focusPane(try #require(model.layout.secondary?.id))
        model.setSplitRatio(0.37)
        model.pinDestination(for: web)
        model.agentController.question = "A 的草稿"
        model.agentsVisible = false
        let layout = model.layout
        let recents = model.recentResourceIDs
        let b = try #require(model.createWorkspace(name: "B"))
        #expect(model.tabs.isEmpty)
        #expect(model.agentController !== a.agentController)
        model.agentController.question = "B 的草稿"
        model.newTab()
        model.selectWorkspace(a.id)
        #expect(model.layout == layout)
        #expect(model.webRuntimes.terminalSession(for: terminal) === terminalSession)
        #expect(model.agentController.question == "A 的草稿")
        #expect(model.pinnedDestinations.count == 1)
        #expect(model.recentResourceIDs == recents)
        #expect(!model.agentsVisible)
        model.selectWorkspace(b)
        #expect(model.agentController.question == "B 的草稿")
        #expect(model.layout.secondary == nil)
        #expect(model.pinnedDestinations.isEmpty)
    }

    @Test func backgroundWebCallbacksRemainWithOriginalOwner() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        model.newTab()
        let a = model.session
        let source = model.selectedTabID
        let committed = try #require(a.resourceStore.onCommit)
        let popup = try #require(a.resourceStore.onOpenInNewTab)
        let state = try #require(a.resourceStore.onStateChange)
        let b = try #require(model.createWorkspace(name: "B"))
        let bLayout = model.layout
        let url = URL(string: "https://example.test/late")!
        committed(source, url)
        state(source, WebNavigationState(pageTitle: "A 的迟到标题"))
        popup(source, URL(string: "https://example.test/popup")!)
        #expect(model.session.id == b)
        #expect(model.tabs.isEmpty)
        #expect(model.layout == bLayout)
        #expect(a.resourceStore.records[source]?.location == .web(url))
        #expect(a.resourceStore.records[source]?.title == "A 的迟到标题")
        #expect(a.resourceStore.resources.count == 2)
    }

    @Test func existingWindowSelectionDoesNotAdoptItsStore() throws {
        let registry = WorkspaceRegistry()
        let first = StudioModel(launchTerminalProcesses: false, registry: registry)
        first.newTab()
        let original = first.session.id
        let secondSpace = try #require(first.createWorkspace(name: "Second"))
        let secondWindow = StudioModel(launchTerminalProcesses: false, registry: registry)
        let own = secondWindow.session
        secondWindow.selectWorkspace(original)
        #expect(first.session.id == original)
        #expect(secondWindow.session === own)
        #expect(secondWindow.windowCoordinator.loadedSessions.count == 1)
        secondWindow.newTab(in: secondSpace)
        #expect(first.session.id == secondSpace)
        #expect(first.tabs.isEmpty)
        #expect(secondWindow.tabs.isEmpty)
    }

    @Test func formDraftBlocksSwitchWithoutDiscardingInput() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        let a = model.session.id
        let b = try #require(model.createWorkspace(name: "B"))
        model.openProviderSettings()
        model.providerSettings.modelText = "unsaved-model-draft"
        model.selectWorkspace(a)
        #expect(model.session.id == b)
        #expect(model.providerSettings.modelText == "unsaved-model-draft")
        #expect(model.workspaceNotice != nil)
        model.dismissPanel()
        model.selectWorkspace(a)
        #expect(model.session.id == a)
    }

    @Test func newlyActiveStoreForwardsChangesAndClosedSessionReleases() async throws {
        let model = StudioModel(launchTerminalProcesses: false)
        let a = model.session.id
        let b = try #require(model.createWorkspace(name: "B"))
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        _ = model.webRuntimes.registerWeb(groupID: b)
        #expect(changes > 0)
        weak var old = model.session
        await model.performCloseWorkspace(b)
        #expect(model.session.id == a)
        #expect(old == nil)
        withExtendedLifetime(observation) {}
    }

    @Test func splitWithoutArgumentOnlyOpensChooser() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        model.newTab()
        let before = model.webRuntimes.resources.count
        let layout = model.layout
        model.split()
        #expect(model.splitPickerPresented)
        #expect(model.webRuntimes.resources.count == before)
        #expect(model.layout == layout)
    }

    @Test func splitChooserSelectionsMountExplicitResourceOrNewResource() throws {
        let model = StudioModel(launchTerminalProcesses: false)
        model.newTab()
        let first = model.selectedTabID
        let second = model.webRuntimes.registerWeb(groupID: model.session.id)
        model.split()
        model.chooseSplitResource(second)
        #expect(model.layout.secondary?.resourceID == second)
        model.returnToSinglePane()
        model.split()
        model.splitWithNewWeb()
        #expect(model.layout.secondary?.resourceID != nil)
        #expect(model.webRuntimes.resources.count == 3)
        _ = first
    }
}
