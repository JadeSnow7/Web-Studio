import Foundation
import Testing

@testable import Web_Studio

@MainActor
struct WorkspaceCopyTests {
  actor CopyGate {
    var waiter: CheckedContinuation<Void, Never>?
    var released = false
    func wait() async {
      if released { return }
      await withCheckedContinuation { waiter = $0 }
    }
    func release() {
      released = true
      waiter?.resume()
      waiter = nil
    }
    func isWaiting() -> Bool { waiter != nil }
  }
  private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("WebStudio-Copy-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func loadedCopyCreatesIdleResourceAndKeepsSource() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = WorkspaceRepository(rootURL: root)
    let registry = WorkspaceRegistry(repository: repository)
    let source = registry.create(name: "source", isTemporary: true, launchTerminalProcesses: false)
    let target = registry.create(name: "target", isTemporary: true, launchTerminalProcesses: false)
    let resourceID = source.resourceStore.registerWeb(
      groupID: source.id, destination: URL(string: "https://example.com"))
    let sourceQuestionCount = source.agentController.questions.count
    let copiedID = try await registry.copyResource(
      sourceWorkspaceID: source.id, resourceID: resourceID, toWorkspaceID: target.id)
    #expect(copiedID != resourceID)
    #expect(source.resourceStore.records[resourceID] != nil)
    #expect(source.agentController.questions.count == sourceQuestionCount)
    #expect(target.resourceStore.records[copiedID]?.lifecycle == .idle)
    #expect(target.resourceStore.activeRuntimeCount == 0)
  }

  @Test func unloadedCopyUsesCASAndDoesNotCreateSession() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceID = UUID()
    let targetID = UUID()
    let resourceID = UUID()
    let source = WorkspaceConfiguration(
      workspaceID: sourceID, name: "source",
      resources: [
        .init(
          id: resourceID, destination: .terminal(directory: "/tmp"), customTitle: "term", order: 0)
      ],
      layout: .init(
        primary: .init(id: UUID(), resourceID: resourceID, isFocused: true),
        secondary: nil, splitRatio: 0.5))
    let target = WorkspaceConfiguration(
      workspaceID: targetID, name: "target", resources: [],
      layout: .init(
        primary: .init(id: UUID(), resourceID: nil, isFocused: true),
        secondary: nil, splitRatio: 0.5))
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(source)
    _ = try await repository.save(target)
    let registry = WorkspaceRegistry(repository: repository)
    await registry.startRestoration()
    let copied = try await registry.copyResource(
      sourceWorkspaceID: sourceID, resourceID: resourceID, toWorkspaceID: targetID)
    #expect(registry.liveSessions.isEmpty)
    guard let result = try? await repository.load(id: targetID), case .loaded(let envelope) = result else {
      Issue.record("expected target configuration")
      return
    }
    #expect(envelope.configuration.resources.count == 1)
    #expect(envelope.configuration.resources[0].id == copied)
    #expect(envelope.configuration.layout == target.layout)
  }

  @Test func archivedAndSameWorkspaceCopiesReject() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = WorkspaceRegistry(repository: WorkspaceRepository(rootURL: root))
    let session = registry.create(name: "A", isTemporary: true, launchTerminalProcesses: false)
    let resource = session.resourceStore.registerWeb(groupID: session.id)
    await #expect(throws: WorkspaceCopyError.targetUnavailable) {
      try await registry.copyResource(sourceWorkspaceID: session.id, resourceID: resource, toWorkspaceID: session.id)
    }
    let target = registry.create(launchTerminalProcesses: false)
    target.archived = true
    await #expect(throws: WorkspaceCopyError.archivedWorkspace) {
      try await registry.copyResource(sourceWorkspaceID: session.id, resourceID: resource, toWorkspaceID: target.id)
    }
  }

  @Test func unloadedCopyCASConflictPreservesExternalTarget() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceID = UUID()
    let targetID = UUID()
    let resourceID = UUID()
    let source = WorkspaceConfiguration(
      workspaceID: sourceID, name: "source",
      resources: [
        .init(
          id: resourceID, destination: .web(url: "https://example.com"), customTitle: nil, order: 0)
      ],
      layout: .init(primary: .init(id: UUID(), resourceID: nil, isFocused: true), secondary: nil, splitRatio: 0.5))
    let target = WorkspaceConfiguration(
      workspaceID: targetID, name: "target",
      layout: .init(
        primary: .init(id: UUID(), resourceID: nil, isFocused: true), secondary: nil, splitRatio: 0.5))
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(source)
    _ = try await repository.save(target)
    let registry = WorkspaceRegistry(
      repository: repository,
      configurationLoader: { id in
        let result = try await repository.load(id: id)
        if id == targetID {
          switch result {
          case .loaded(let envelope), .recoveredFromBackup(let envelope):
            var external = envelope.configuration
            external.name = "external"
            _ = try await repository.save(external, expectedRevision: envelope.configuration.revision)
          }
        }
        return result
      })
    await registry.startRestoration()
    await #expect(throws: WorkspaceCopyError.conflict) {
      try await registry.copyResource(sourceWorkspaceID: sourceID, resourceID: resourceID, toWorkspaceID: targetID)
    }
    guard let result = try? await repository.load(id: targetID), case .loaded(let envelope) = result else {
      Issue.record("expected external target")
      return
    }
    #expect(envelope.configuration.name == "external")
    #expect(envelope.configuration.resources.isEmpty)
  }

  @Test func loadedTerminalCopyPreservesSourceAndCreatesNoRuntime() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = WorkspaceRegistry(repository: WorkspaceRepository(rootURL: root))
    let source = registry.create(launchTerminalProcesses: false)
    let target = registry.create(launchTerminalProcesses: false)
    let resourceID = source.resourceStore.registerLocalTerminal(
      groupID: source.id, directory: FileManager.default.temporaryDirectory.path)
    let sourceRecord = source.resourceStore.records[resourceID]
    let sourceTerminal = source.resourceStore.terminalSession(for: resourceID)
    source.agentController.question = "draft"
    let copiedID = try await registry.copyResource(
      sourceWorkspaceID: source.id, resourceID: resourceID, toWorkspaceID: target.id)
    #expect(source.resourceStore.records[resourceID] == sourceRecord)
    #expect(source.resourceStore.activeTerminalSessionCount == 1)
    #expect(source.resourceStore.terminalSession(for: resourceID) === sourceTerminal)
    #expect(source.agentController.question == "draft")
    #expect(target.resourceStore.records[copiedID]?.kind == .localTerminal)
    #expect(target.resourceStore.records[copiedID]?.lifecycle == .idle)
    #expect(target.resourceStore.terminalFactoryCreationCount == 0)
  }

  @Test func openSavedWaitsForCopyToFinish() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceID = UUID()
    let targetID = UUID()
    let resourceID = UUID()
    let source = WorkspaceConfiguration(
      workspaceID: sourceID, name: "source",
      resources: [
        .init(
          id: resourceID, destination: .web(url: "https://example.com"), customTitle: nil, order: 0)
      ],
      layout: .init(primary: .init(id: UUID(), resourceID: nil, isFocused: true), secondary: nil, splitRatio: 0.5))
    let target = WorkspaceConfiguration(
      workspaceID: targetID, name: "target",
      layout: .init(
        primary: .init(id: UUID(), resourceID: nil, isFocused: true), secondary: nil, splitRatio: 0.5))
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(source)
    _ = try await repository.save(target)
    actor Gate {
      var waiter: CheckedContinuation<Void, Never>?
      var released = false
      func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
      }
      func release() {
        released = true
        waiter?.resume()
        waiter = nil
      }
      func isWaiting() -> Bool { waiter != nil }
    }
    let gate = Gate()
    let registry = WorkspaceRegistry(
      repository: repository,
      configurationLoader: { id in
        if id == targetID { await gate.wait() }
        return try await repository.load(id: id)
      })
    await registry.startRestoration()
    let copyTask = Task {
      try await registry.copyResource(
        sourceWorkspaceID: sourceID, resourceID: resourceID, toWorkspaceID: targetID)
    }
    while !(await gate.isWaiting()) { await Task.yield() }
    let coordinator = WindowCoordinator(registry: registry)
    let openTask = Task { await registry.openSaved(targetID, in: coordinator, launchTerminalProcesses: false) }
    #expect(registry.session(for: targetID) == nil)
    await gate.release()
    _ = try await copyTask.value
    let result = await openTask.value
    guard case .opened(let opened) = result else {
      Issue.record("expected opened target")
      return
    }
    #expect(opened.resourceStore.resources.count == 1)
    #expect(opened.resourceStore.terminalFactoryCreationCount == 0)
  }

  @Test func invalidResourceDoesNotMutateSource() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = WorkspaceRegistry(repository: WorkspaceRepository(rootURL: root))
    let source = registry.create(launchTerminalProcesses: false)
    let target = registry.create(launchTerminalProcesses: false)
    await #expect(throws: WorkspaceCopyError.resourceUnavailable) {
      try await registry.copyResource(sourceWorkspaceID: source.id, resourceID: UUID(), toWorkspaceID: target.id)
    }
    #expect(source.resourceStore.records.isEmpty)
  }

  @Test func searchIncludesLoadedTemporaryWithoutCreatingRuntime() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = WorkspaceRegistry(repository: WorkspaceRepository(rootURL: root))
    let session = registry.create(launchTerminalProcesses: false)
    _ = session.resourceStore.registerWeb(groupID: session.id)
    let values = await registry.configurationsForSearch()
    #expect(values.contains { $0.workspaceID == session.id })
    #expect(session.resourceStore.activeRuntimeCount == 0)
  }

  @Test func explicitOpenSavedPreservesDraft() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let config = WorkspaceConfiguration(
      workspaceID: id, name: "saved",
      layout: .init(primary: .init(id: UUID(), resourceID: nil, isFocused: true), secondary: nil, splitRatio: 0.5))
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(config)
    let registry = WorkspaceRegistry(repository: repository)
    await registry.startRestoration()
    let draftSession = registry.create(launchTerminalProcesses: false)
    draftSession.agentController.question = "draft"
    let coordinator = WindowCoordinator(registry: registry)
    #expect(coordinator.open(draftSession.id) != .unavailable)
    #expect(coordinator.activeWorkspaceID == draftSession.id)
    #expect(await registry.openSaved(id, in: coordinator, launchTerminalProcesses: false) != .unavailable)
    #expect(draftSession.agentController.question == "draft")
  }

  @Test func sourceCloseDuringCopyRejectsAndLeavesTargetUnchanged() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceID = UUID()
    let targetID = UUID()
    let resourceID = UUID()
    let sourceConfig = WorkspaceConfiguration(
      workspaceID: sourceID, name: "source",
      resources: [
        .init(
          id: resourceID, destination: .web(url: "https://example.com"), customTitle: nil, order: 0)
      ],
      layout: .init(primary: .init(id: UUID(), resourceID: nil, isFocused: true), secondary: nil, splitRatio: 0.5))
    let targetConfig = WorkspaceConfiguration(
      workspaceID: targetID, name: "target",
      layout: .init(primary: .init(id: UUID(), resourceID: nil, isFocused: true), secondary: nil, splitRatio: 0.5))
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(sourceConfig)
    _ = try await repository.save(targetConfig)
    let gate = CopyGate()
    let registry = WorkspaceRegistry(
      repository: repository,
      configurationLoader: { id in
        if id == targetID { await gate.wait() }
        return try await repository.load(id: id)
      })
    await registry.startRestoration()
    let sourceCoordinator = WindowCoordinator(registry: registry)
    guard case .opened = await registry.openSaved(sourceID, in: sourceCoordinator, launchTerminalProcesses: false)
    else {
      Issue.record("expected source open")
      return
    }
    let copy = Task {
      try await registry.copyResource(sourceWorkspaceID: sourceID, resourceID: resourceID, toWorkspaceID: targetID)
    }
    while !(await gate.isWaiting()) { await Task.yield() }
    await sourceCoordinator.closeWorkspace(sourceID)
    await gate.release()
    await #expect(throws: WorkspaceCopyError.sourceUnavailable) { try await copy.value }
    let result = try await repository.load(id: targetID)
    switch result {
    case .loaded(let envelope), .recoveredFromBackup(let envelope):
      #expect(envelope.configuration.resources.isEmpty)
    }
  }

  @Test func openSavedCopyWaitPreservesEditedDraft() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceID = UUID()
    let targetID = UUID()
    let resourceID = UUID()
    let source = WorkspaceConfiguration(
      workspaceID: sourceID, name: "source",
      resources: [
        .init(
          id: resourceID, destination: .blank, customTitle: nil, order: 0)
      ],
      layout: .init(primary: .init(id: UUID(), resourceID: nil, isFocused: true), secondary: nil, splitRatio: 0.5))
    let target = WorkspaceConfiguration(
      workspaceID: targetID, name: "target",
      layout: .init(primary: .init(id: UUID(), resourceID: nil, isFocused: true), secondary: nil, splitRatio: 0.5))
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(source)
    _ = try await repository.save(target)
    let gate = CopyGate()
    let registry = WorkspaceRegistry(
      repository: repository,
      configurationLoader: { id in
        if id == targetID { await gate.wait() }
        return try await repository.load(id: id)
      })
    await registry.startRestoration()
    let copy = Task {
      try await registry.copyResource(sourceWorkspaceID: sourceID, resourceID: resourceID, toWorkspaceID: targetID)
    }
    while !(await gate.isWaiting()) { await Task.yield() }
    let draft = registry.create(launchTerminalProcesses: false)
    draft.agentController.question = "before"
    var entered = false
    let coordinator = WindowCoordinator(registry: registry)
    #expect(coordinator.open(draft.id) != .unavailable)
    let open = Task {
      entered = true
      return await registry.openSaved(targetID, in: coordinator, launchTerminalProcesses: false)
    }
    while !entered { await Task.yield() }
    draft.agentController.question = "after"
    await gate.release()
    _ = try await copy.value
    #expect(await open.value == .unavailable)
    #expect(coordinator.activeWorkspaceID == draft.id)
    #expect(draft.agentController.question == "after")
  }
}
