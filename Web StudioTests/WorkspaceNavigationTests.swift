import Foundation
import Testing

@testable import Web_Studio

@MainActor
struct WorkspaceNavigationTests {
  private func fixtureRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("WebStudio-Navigation-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func searchFlattensSameNamedResourcesWithCurrentFirstAndStableIDs() async throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = WorkspaceRepository(rootURL: root)
    let registry = WorkspaceRegistry(repository: repository)
    let model = StudioModel(launchTerminalProcesses: false, registry: registry)
    model.session.name = "当前空间"
    let currentID = model.session.id
    let currentResource = model.webRuntimes.registerWeb(
      groupID: currentID, destination: URL(string: "https://same.example/current"))
    if var record = model.webRuntimes.records[currentResource] {
      record.customTitle = "同名"
      model.webRuntimes.update(record)
    }
    let otherID = UUID()
    let otherResource = UUID()
    let other = WorkspaceConfiguration(
      workspaceID: otherID, name: "另一空间",
      resources: [
        .init(id: otherResource, destination: .web(url: "https://same.example/other"), customTitle: "同名", order: 0),
        .init(id: UUID(), destination: .web(url: "https://unrelated.example"), customTitle: "无关", order: 1),
      ],
      layout: .init(
        primary: .init(id: UUID(), resourceID: otherResource, isFocused: true), secondary: nil, splitRatio: 0.5))
    _ = try await repository.save(model.session.exportConfiguration())
    _ = try await repository.save(other)
    await registry.startRestoration()

    await model.refreshSearchResults("同名")
    #expect(model.searchResults.count == 2)
    #expect(model.searchResults.first?.workspaceID == currentID)
    #expect(Set(model.searchResults.map(\.id)).count == 2)
    #expect(model.webRuntimes.activeRuntimeCount == 0)
    model.searchAllWorkspaces = false
    await model.refreshSearchResults("同名")
    #expect(model.searchResults.map(\.resourceID) == [currentResource])
  }

  @Test func searchAndOpenLoadedTemporaryResourceSucceedsWithoutRuntime() async throws {
    let model = StudioModel(launchTerminalProcesses: false)
    let resourceID = model.webRuntimes.registerWeb(
      groupID: model.session.id, destination: URL(string: "https://temporary.example"))
    let result = WorkspaceResourceSearchResult(
      workspaceID: model.session.id, resourceID: resourceID, workspaceName: model.session.name,
      resourceTitle: "临时资源", kind: .web, destinationSummary: "https://temporary.example")
    await model.refreshSearchResults("")
    await model.openSearchResultAsync(result)
    #expect(model.webRuntimes.activeRuntimeCount == 0)
    #expect(model.layout.primary.resourceID == resourceID)
  }

  @Test func paletteQueryMatchesResourceDestinationAndKeepsResourceCommand() async {
    let model = StudioModel(launchTerminalProcesses: false)
    let resourceID = model.webRuntimes.registerWeb(
      groupID: model.session.id, destination: URL(string: "https://keyboard.example"))
    await model.refreshSearchResults("keyboard.example")
    model.commandQuery = "keyboard.example"
    #expect(model.filteredCommandCount == 1)
    guard let command = model.paletteCommands.first else {
      Issue.record("expected resource command")
      return
    }
    guard case .selectWorkspaceResource(let workspaceID, let selectedResourceID) = command.action else {
      Issue.record("expected cross-workspace resource action")
      return
    }
    #expect(workspaceID == model.session.id)
    #expect(selectedResourceID == resourceID)
  }

  @Test func selectingUnloadedTerminalRestoresIdleDescriptorWithoutFactory() async throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspaceID = UUID()
    let resourceID = UUID()
    let configuration = WorkspaceConfiguration(
      workspaceID: workspaceID, name: "终端空间",
      resources: [
        .init(id: resourceID, destination: .terminal(directory: "/tmp"), customTitle: "远端终端", order: 0)
      ],
      layout: .init(
        primary: .init(id: UUID(), resourceID: resourceID, isFocused: true), secondary: nil, splitRatio: 0.5))
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(configuration)
    let registry = WorkspaceRegistry(repository: repository)
    await registry.startRestoration()
    let model = StudioModel(launchTerminalProcesses: false, registry: registry)
    let result = WorkspaceResourceSearchResult(
      workspaceID: workspaceID, resourceID: resourceID, workspaceName: "终端空间",
      resourceTitle: "远端终端", kind: .localTerminal, destinationSummary: "/tmp")
    await model.openSearchResultAsync(result)
    #expect(model.session.id == workspaceID)
    #expect(model.webRuntimes.records[resourceID]?.lifecycle == .idle)
    #expect(model.webRuntimes.terminalFactoryCreationCount == 0)
  }

  @Test func keyboardExecuteSelectedCommandActuallySelectsSearchResource() async {
    let model = StudioModel(launchTerminalProcesses: false)
    let resourceID = model.webRuntimes.registerWeb(
      groupID: model.session.id, destination: URL(string: "https://keyboard.example"))
    model.openCommands()
    model.commandQuery = "keyboard.example"
    await model.refreshSearchResults(model.commandQuery)
    model.commandSelectedIndex = 0
    model.executeSelectedCommand()
    await model.waitForSearchSelection()
    #expect(model.layout.primary.resourceID == resourceID)
    #expect(model.commandPalettePresented == false)
  }

  @Test func existingOtherWindowSelectionOnlyChangesOwnerPane() async {
    let registry = WorkspaceRegistry()
    let model = StudioModel(launchTerminalProcesses: false, registry: registry)
    let sourceID = model.session.id
    let owner = WindowCoordinator(registry: registry)
    let target = registry.create(name: "另一窗口", isTemporary: true, launchTerminalProcesses: false)
    let resourceID = target.resourceStore.registerWeb(
      groupID: target.id, destination: URL(string: "https://other-window.example"))
    _ = owner.open(target.id)
    let originalSourceLayout = model.layout
    let result = WorkspaceResourceSearchResult(
      workspaceID: target.id, resourceID: resourceID, workspaceName: target.name,
      resourceTitle: "他窗资源", kind: .web, destinationSummary: "https://other-window.example")
    await model.openSearchResultAsync(result)
    #expect(model.session.id == sourceID)
    #expect(model.layout == originalSourceLayout)
    #expect(owner.activeWorkspaceID == target.id)
    #expect(target.layout.primary.resourceID == resourceID)
  }
}
