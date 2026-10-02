import Foundation
import Testing

@testable import Web_Studio

@MainActor
struct WorkspaceOwnershipTests {
  @Test func registryKeepsDirectoryWeakAndCoordinatorOwnsLoadedSession() async {
    let registry = WorkspaceRegistry()
    let coordinator = WindowCoordinator(registry: registry)
    let session = coordinator.createWorkspace(launchTerminalProcesses: false)!
    #expect(registry.entries.contains { $0.id == session.id })
    #expect(coordinator.loadedSessions[session.id] === session)
    #expect(registry.session(for: session.id) === session)
    await coordinator.closeWorkspace(session.id)
    #expect(registry.session(for: session.id) == nil)
    #expect(session.isClosed)
  }

  @Test func twoWindowsLocateOneRuntimeAndDoNotReturnForeignSession() {
    let registry = WorkspaceRegistry()
    let first = WindowCoordinator(registry: registry)
    let second = WindowCoordinator(registry: registry)
    let session = first.createWorkspace(launchTerminalProcesses: false)!
    var activated = false
    second.onActivateWindow = { _ in activated = true }
    let result = second.open(session.id)
    #expect(result == .locatedExistingWindow(workspaceID: session.id))
    #expect(second.loadedSessions[session.id] == nil)
    #expect(activated == false)  // no AppKit window was supplied
    #expect(first.loadedSessions[session.id] === session)
  }

  @Test func closeIsIdempotentAndSameIDCanBeReattachedByNewSession() async {
    let registry = WorkspaceRegistry()
    let coordinator = WindowCoordinator(registry: registry)
    let old = coordinator.createWorkspace(launchTerminalProcesses: false)!
    await coordinator.closeWorkspace(old.id)
    await coordinator.closeWorkspace(old.id)
    let replacement = WorkspaceSession(
      id: old.id, name: old.name, isTemporary: old.isTemporary, launchTerminalProcesses: false,
      providerSettings: registry.providerSettings)
    #expect(registry.add(replacement))
    #expect(coordinator.open(replacement.id) == .opened(replacement))
    #expect(coordinator.loadedSessions[replacement.id] === replacement)
  }

  @Test func closedSessionCanBeCollectedAndDifferentInstanceCannotAttachSameID() async {
    let registry = WorkspaceRegistry()
    let coordinator = WindowCoordinator(registry: registry)
    var old: WorkspaceSession? = coordinator.createWorkspace(launchTerminalProcesses: false)
    let id = old!.id
    weak var weakOld: WorkspaceSession?
    weakOld = old
    let conflicting = WorkspaceSession(
      id: id, launchTerminalProcesses: false,
      providerSettings: registry.providerSettings)
    #expect(!registry.attach(conflicting, to: coordinator))
    await coordinator.closeWorkspace(id)
    old = nil
    #expect(registry.session(for: id) == nil)
    #expect(coordinator.loadedSessions[id] == nil)
    #expect(weakOld == nil)
  }

  @Test func sessionsKeepIndependentLayoutPinsAndAgentDraft() {
    let registry = WorkspaceRegistry()
    let a = registry.create(name: "A", launchTerminalProcesses: false)
    let b = registry.create(name: "B", launchTerminalProcesses: false)
    let pane = PaneState(resourceID: nil, isFocused: true)
    a.layout = WorkspaceLayout(primary: pane, splitRatio: 0.3)
    a.pinnedDestinations = [PinnedDestination(title: "A", destination: .blank)]
    a.agentController.question = "draft A"
    #expect(b.layout != a.layout)
    #expect(b.pinnedDestinations.isEmpty)
    #expect(b.agentController.question.isEmpty)
  }

  @Test func providerConfigurationPropagatesToAllLiveSessions() throws {
    let registry = WorkspaceRegistry()
    let a = registry.create(launchTerminalProcesses: false)
    let b = registry.create(launchTerminalProcesses: false)
    let configuration = try ProviderConfiguration(
      endpoint: "https://example.com/v1/responses", model: "model")
    registry.updateProviderConfiguration(configuration)
    #expect(a.agentController.configuration == configuration)
    #expect(b.agentController.configuration == configuration)
  }
}
