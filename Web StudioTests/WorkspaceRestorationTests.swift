import Foundation
import Testing

@testable import Web_Studio

private actor RestorationLoadGate {
  private var pending: [UUID: CheckedContinuation<WorkspaceLoadResult, Never>] = [:]
  func load(_ id: UUID) async -> WorkspaceLoadResult {
    await withCheckedContinuation { pending[id] = $0 }
  }
  func waiting(_ id: UUID) -> Bool { pending[id] != nil }
  func release(_ id: UUID, result: WorkspaceLoadResult) {
    pending[id]?.resume(returning: result)
    pending[id] = nil
  }
}

private actor RestorationDirectoryGate {
  private var continuation: CheckedContinuation<[WorkspaceRepositoryEntry], Never>?
  func load() async -> [WorkspaceRepositoryEntry] {
    await withCheckedContinuation { continuation = $0 }
  }
  func waiting() -> Bool { continuation != nil }
  func release(_ entries: [WorkspaceRepositoryEntry]) {
    continuation?.resume(returning: entries)
    continuation = nil
  }
}

@MainActor
struct WorkspaceRestorationTests {
  private func root() throws -> URL {
    let value = FileManager.default.temporaryDirectory
      .appendingPathComponent("WebStudio-Restore-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
    return value
  }

  @Test func savedSessionClosesAndReopensAsNewRuntime() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let configuration = WorkspaceConfiguration(
      workspaceID: id, revision: 1, name: "Saved", directory: nil,
      resources: [.init(id: UUID(), destination: .blank, customTitle: nil, order: 0)],
      layout: .init(
        primary: .init(id: UUID(), resourceID: nil, isFocused: true),
        secondary: nil, splitRatio: 0.5))
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(configuration)
    let registry = WorkspaceRegistry(repository: repository)
    await registry.startRestoration()
    let firstCoordinator = WindowCoordinator(registry: registry)
    guard case .opened = await registry.openSaved(id, in: firstCoordinator) else {
      Issue.record("expected first open")
      return
    }
    var firstSession: WorkspaceSession? = registry.session(for: id)
    weak var weakFirst: WorkspaceSession? = firstSession
    await firstCoordinator.closeWorkspace(id)
    firstSession = nil
    #expect(weakFirst == nil)
    #expect(registry.session(for: id) == nil)
    #expect(registry.entries.contains { $0.id == id })
    let secondCoordinator = WindowCoordinator(registry: registry)
    guard case .opened(let second) = await registry.openSaved(id, in: secondCoordinator) else {
      Issue.record("expected reopen")
      return
    }
    #expect(weakFirst == nil)
    #expect(second.resourceStore.resources.map { $0.id } == configuration.resources.map { $0.id })
  }

  @Test func archiveHidesEntryAndUnarchiveRestoresIt() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(
      WorkspaceConfiguration(
        workspaceID: id, name: "Archive",
        layout: .init(
          primary: .init(id: UUID(), resourceID: nil, isFocused: true), splitRatio: 0.5)))
    let registry = WorkspaceRegistry(repository: repository)
    await registry.startRestoration()
    #expect(await registry.archive(id))
    #expect(!registry.entries.contains { $0.id == id })
    #expect(registry.archivedEntries.contains { $0.id == id })
    #expect(await registry.unarchive(id))
    #expect(registry.entries.contains { $0.id == id })
  }

  @Test func searchSnapshotDoesNotCreateLoadedSession() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(
      WorkspaceConfiguration(
        workspaceID: id, name: "Search",
        layout: .init(
          primary: .init(id: UUID(), resourceID: nil, isFocused: true), splitRatio: 0.5)))
    let registry = WorkspaceRegistry(repository: repository)
    await registry.startRestoration()
    let snapshots = await registry.configurationsForSearch()
    #expect(snapshots.count == 1)
    #expect(registry.liveSessions.isEmpty)
  }

  @Test func namedSessionAutosavesAndTemporaryRenamePersists() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = WorkspaceRepository(rootURL: root)
    let registry = WorkspaceRegistry(repository: repository)
    let named = registry.create(
      name: "Named", isTemporary: false,
      launchTerminalProcesses: false)
    named.name = "Renamed"
    guard registry.saveController(for: named.id) != nil else {
      Issue.record("expected save controller")
      return
    }
    var result: WorkspaceLoadResult?
    for _ in 0..<20 {
      result = try? await repository.load(id: named.id)
      if case .loaded(let envelope)? = result, envelope.configuration.name == "Renamed" { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    let savedNamed = try #require(result)
    guard case .loaded(let namedEnvelope) = savedNamed else {
      Issue.record("expected saved configuration")
      return
    }
    #expect(namedEnvelope.configuration.name == "Renamed")

    let temporary = registry.create(launchTerminalProcesses: false)
    let temporaryURL = root.appendingPathComponent("\(temporary.id.uuidString).json")
    #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    #expect(registry.rename(temporary.id, name: "Saved temporary"))
    #expect(temporary.isTemporary == false)
    guard registry.saveController(for: temporary.id) != nil else {
      Issue.record("expected renamed temporary save controller")
      return
    }
    var temporaryResult: WorkspaceLoadResult?
    for _ in 0..<20 {
      temporaryResult = try? await repository.load(id: temporary.id)
      if case .loaded(let envelope) = temporaryResult, envelope.configuration.name == "Saved temporary" { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    let savedTemporary = try #require(temporaryResult)
    guard case .loaded(let temporaryEnvelope) = savedTemporary else {
      Issue.record("expected renamed temporary to save")
      return
    }
    #expect(temporaryEnvelope.configuration.name == "Saved temporary")
    #expect(registry.entries.contains { $0.id == temporary.id })
  }

  @Test func restoreLastActiveLoadsOnlyOneWorkspace() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = WorkspaceRepository(rootURL: root)
    let older = WorkspaceConfiguration(
      workspaceID: UUID(), revision: 1, name: "Older", directory: nil,
      layout: .init(primary: .init(id: UUID(), resourceID: nil, isFocused: true), splitRatio: 0.5),
      lastActivatedAt: Date(timeIntervalSince1970: 10))
    let newer = WorkspaceConfiguration(
      workspaceID: UUID(), revision: 1, name: "Newer", directory: nil,
      layout: .init(primary: .init(id: UUID(), resourceID: nil, isFocused: true), splitRatio: 0.5),
      lastActivatedAt: Date(timeIntervalSince1970: 20))
    _ = try await repository.save(older)
    _ = try await repository.save(newer)
    let registry = WorkspaceRegistry(repository: repository)
    let coordinator = WindowCoordinator(registry: registry)
    let result = await registry.restoreLastActive(
      in: coordinator,
      launchTerminalProcesses: false)
    guard case .opened(let session) = result else {
      Issue.record("expected last active workspace to open")
      return
    }
    #expect(session.id == newer.workspaceID)
    #expect(registry.liveSessions.count == 1)
  }

  @Test func restoredTerminalAndSSHDescriptionsCreateNoRuntime() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let terminalID = UUID()
    let sshID = UUID()
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(
      WorkspaceConfiguration(
        workspaceID: id, name: "Runtime free",
        resources: [
          .init(
            id: terminalID, destination: .terminal(directory: "/path/that/does/not/exist"), customTitle: nil, order: 0),
          .init(
            id: sshID, destination: .ssh(host: "dev.example.com", user: "dev", port: 22), customTitle: nil, order: 1),
        ], layout: .init(primary: .init(id: UUID(), resourceID: terminalID, isFocused: true), splitRatio: 0.5)))
    let registry = WorkspaceRegistry(repository: repository)
    await registry.startRestoration()
    let coordinator = WindowCoordinator(registry: registry)
    guard case .opened(let session) = await registry.openSaved(id, in: coordinator, launchTerminalProcesses: false)
    else {
      Issue.record("expected saved workspace")
      return
    }
    #expect(session.resourceStore.terminalFactoryCreationCount == 0)
    #expect(session.resourceStore.resources.map(\.id) == [terminalID, sshID])
    #expect(session.resourceStore.records[terminalID]?.lifecycle == .idle)
    #expect(session.resourceStore.records[sshID]?.lifecycle == .idle)
  }

  @Test func existingTemporarySpaceDoesNotDisplaceSavedLastActiveRestore() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let older = configurationForRestoration(id: UUID(), name: "Older", active: Date(timeIntervalSince1970: 10))
    let newer = configurationForRestoration(id: UUID(), name: "Newer", active: Date(timeIntervalSince1970: 20))
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(older)
    _ = try await repository.save(newer)
    let registry = WorkspaceRegistry(repository: repository)
    let coordinator = WindowCoordinator(registry: registry)
    let temporary = try #require(coordinator.createWorkspace(launchTerminalProcesses: false))
    #expect(coordinator.activeWorkspaceID == temporary.id)
    guard case .opened(let restored) = await registry.restoreLastActive(in: coordinator, launchTerminalProcesses: false)
    else {
      Issue.record("expected saved last active workspace")
      return
    }
    #expect(restored.id == newer.workspaceID)
    #expect(restored.id != temporary.id)
    #expect(registry.liveSessions.count == 2)
  }

  @Test func concurrentOpenUsesOneOwnerAndReopenCreatesNewSession() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(configurationForRestoration(id: id, name: "Shared", active: Date()))
    let registry = WorkspaceRegistry(repository: repository)
    await registry.startRestoration()
    let firstCoordinator = WindowCoordinator(registry: registry)
    let secondCoordinator = WindowCoordinator(registry: registry)
    async let firstResult = registry.openSaved(id, in: firstCoordinator, launchTerminalProcesses: false)
    async let secondResult = registry.openSaved(id, in: secondCoordinator, launchTerminalProcesses: false)
    let results = await [firstResult, secondResult]
    #expect(
      results.contains {
        if case .opened = $0 { return true }
        return false
      })
    #expect(
      results.contains {
        if case .locatedExistingWindow = $0 { return true }
        return false
      })
    #expect(registry.coordinator(for: id) === firstCoordinator || registry.coordinator(for: id) === secondCoordinator)
    await registry.close(id)
    #expect(registry.session(for: id) == nil)
    let reopenedCoordinator = WindowCoordinator(registry: registry)
    guard
      case .opened(let reopened) = await registry.openSaved(id, in: reopenedCoordinator, launchTerminalProcesses: false)
    else {
      Issue.record("expected reopen")
      return
    }
    #expect(reopened.resourceStore.activeTerminalSessionCount == 0)
  }

  private func configurationForRestoration(id: UUID, name: String, active: Date) -> WorkspaceConfiguration {
    WorkspaceConfiguration(
      workspaceID: id, name: name,
      layout: .init(primary: .init(id: UUID(), resourceID: nil, isFocused: true), splitRatio: 0.5),
      lastActivatedAt: active)
  }

  @Test func concurrentGatedLoadsKeepTheLastCompletedSelection() async throws {
    let b = configurationForRestoration(id: UUID(), name: "B", active: Date())
    let c = configurationForRestoration(id: UUID(), name: "C", active: Date())
    let gate = RestorationLoadGate()
    let entries = [b, c].map {
      WorkspaceRepositoryEntry.entry(
        .init(
          workspaceID: $0.workspaceID, name: $0.name, archived: false, revision: 1, lastActivatedAt: $0.lastActivatedAt)
      )
    }
    let registry = WorkspaceRegistry(configurationLoader: { id in await gate.load(id) }, directoryLoader: { entries })
    await registry.startRestoration()
    let coordinator = WindowCoordinator(registry: registry)
    async let bResult = registry.openSaved(b.workspaceID, in: coordinator, launchTerminalProcesses: false)
    for _ in 0..<1000 {
      if await gate.waiting(b.workspaceID) { break }
      await Task.yield()
    }
    async let cResult = registry.openSaved(c.workspaceID, in: coordinator, launchTerminalProcesses: false)
    for _ in 0..<1000 {
      if await gate.waiting(c.workspaceID) { break }
      await Task.yield()
    }
    await gate.release(c.workspaceID, result: .loaded(.init(configuration: c, diagnostics: [])))
    guard case .opened = await cResult else {
      Issue.record("expected C to open")
      return
    }
    await gate.release(b.workspaceID, result: .loaded(.init(configuration: b, diagnostics: [])))
    guard case .unavailable = await bResult else {
      Issue.record("stale B load replaced C")
      return
    }
    #expect(coordinator.activeWorkspaceID == c.workspaceID)
  }

  @Test func closeWindowDuringPendingLoadDoesNotLeakSession() async throws {
    let config = configurationForRestoration(id: UUID(), name: "Pending", active: Date())
    let gate = RestorationLoadGate()
    let entry = WorkspaceRepositoryEntry.entry(
      .init(
        workspaceID: config.workspaceID, name: config.name, archived: false, revision: 1,
        lastActivatedAt: config.lastActivatedAt))
    let registry = WorkspaceRegistry(configurationLoader: { id in await gate.load(id) }, directoryLoader: { [entry] })
    await registry.startRestoration()
    let coordinator = WindowCoordinator(registry: registry)
    async let opening = registry.openSaved(config.workspaceID, in: coordinator, launchTerminalProcesses: false)
    for _ in 0..<1000 {
      if await gate.waiting(config.workspaceID) { break }
      await Task.yield()
    }
    await coordinator.closeAll()
    await gate.release(config.workspaceID, result: .loaded(.init(configuration: config, diagnostics: [])))
    guard case .unavailable = await opening else {
      Issue.record("pending load opened after close")
      return
    }
    #expect(registry.liveSessions.isEmpty)
  }

  @Test func pendingLoadDoesNotDiscardCurrentDraft() async throws {
    let config = configurationForRestoration(id: UUID(), name: "Loaded", active: Date())
    let gate = RestorationLoadGate()
    let entry = WorkspaceRepositoryEntry.entry(
      .init(
        workspaceID: config.workspaceID, name: config.name, archived: false, revision: 1,
        lastActivatedAt: config.lastActivatedAt))
    let registry = WorkspaceRegistry(configurationLoader: { id in await gate.load(id) }, directoryLoader: { [entry] })
    await registry.startRestoration()
    let coordinator = WindowCoordinator(registry: registry)
    let temporary = try #require(coordinator.createWorkspace(launchTerminalProcesses: false))
    async let opening = registry.openSaved(config.workspaceID, in: coordinator, launchTerminalProcesses: false)
    for _ in 0..<1000 {
      if await gate.waiting(config.workspaceID) { break }
      await Task.yield()
    }
    temporary.agentController.question = "保留草稿"
    await gate.release(config.workspaceID, result: .loaded(.init(configuration: config, diagnostics: [])))
    guard case .unavailable = await opening else {
      Issue.record("load switched away from changed draft")
      return
    }
    #expect(coordinator.activeSession?.agentController.question == "保留草稿")
  }

  @Test func unknownSchemaAndRecoveredBackupRemainVisibleAsDiagnostics() async throws {
    let unknownID = UUID()
    let recoveredID = UUID()
    let recovered = configurationForRestoration(id: recoveredID, name: "Recovered", active: Date())
    let unknown = WorkspaceRepositoryEntry.diagnostic(unknownID, .unknownSchema(unknownID, 99))
    let recoveredEntry = WorkspaceRepositoryEntry.entry(
      .init(
        workspaceID: recoveredID, name: recovered.name, archived: false, revision: 1,
        lastActivatedAt: recovered.lastActivatedAt))
    let registry = WorkspaceRegistry(
      configurationLoader: { id in
        if id == recoveredID { return .recoveredFromBackup(.init(configuration: recovered, diagnostics: [])) }
        throw WorkspaceRepositoryError.unknownSchema(id, 99)
      }, directoryLoader: { [unknown, recoveredEntry] })
    await registry.startRestoration()
    #expect(registry.diagnostics.contains(.unknownSchema(unknownID, 99)))
    let coordinator = WindowCoordinator(registry: registry)
    guard case .opened = await registry.openSaved(recoveredID, in: coordinator, launchTerminalProcesses: false) else {
      Issue.record("expected recovered open")
      return
    }
    #expect(registry.recoveryWorkspaceIDs.contains(recoveredID))
    #expect(registry.loadDiagnostics[unknownID] == nil)
  }

  @Test func directoryScanCannotReplaceDraftChangedWhileRestorationWaits() async throws {
    let saved = configurationForRestoration(id: UUID(), name: "Saved", active: Date())
    let entry = WorkspaceRepositoryEntry.entry(
      .init(
        workspaceID: saved.workspaceID, name: saved.name, archived: false, revision: 1,
        lastActivatedAt: saved.lastActivatedAt))
    let directoryGate = RestorationDirectoryGate()
    let registry = WorkspaceRegistry(
      configurationLoader: { _ in .loaded(.init(configuration: saved, diagnostics: [])) },
      directoryLoader: { await directoryGate.load() })
    let coordinator = WindowCoordinator(registry: registry)
    let temporary = try #require(coordinator.createWorkspace(launchTerminalProcesses: false))
    async let restoring = registry.restoreLastActive(in: coordinator, launchTerminalProcesses: false)
    for _ in 0..<1000 {
      if await directoryGate.waiting() { break }
      await Task.yield()
    }
    temporary.agentController.question = "启动时保留"
    await directoryGate.release([entry])
    guard case .unavailable = await restoring else {
      Issue.record("directory scan replaced changed draft")
      return
    }
    #expect(coordinator.activeWorkspaceID == temporary.id)
    #expect(coordinator.activeSession?.agentController.question == "启动时保留")
  }

  @Test func loadErrorPreservesCurrentActiveSpace() async throws {
    let badID = UUID()
    let currentID = UUID()
    let current = configurationForRestoration(id: currentID, name: "Current", active: Date())
    let badEntry = WorkspaceRepositoryEntry.entry(
      .init(workspaceID: badID, name: "Bad", archived: false, revision: 1, lastActivatedAt: Date()))
    let registry = WorkspaceRegistry(
      configurationLoader: { id in throw WorkspaceRepositoryError.corrupt(id) }, directoryLoader: { [badEntry] })
    await registry.startRestoration()
    let coordinator = WindowCoordinator(registry: registry)
    let active = try #require(coordinator.createWorkspace(name: current.name, launchTerminalProcesses: false))
    guard case .unavailable = await registry.openSaved(badID, in: coordinator, launchTerminalProcesses: false) else {
      Issue.record("corrupt load unexpectedly opened")
      return
    }
    #expect(coordinator.activeWorkspaceID == active.id)
    #expect(registry.loadDiagnostics[badID] == .corrupt(badID))
  }
}
