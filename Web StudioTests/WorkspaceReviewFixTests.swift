import Foundation
import Testing
@testable import Web_Studio

private actor ReviewLoadGate {
  private var pending: [UUID: CheckedContinuation<WorkspaceLoadResult, Never>] = [:]

  func load(_ id: UUID) async -> WorkspaceLoadResult {
    await withCheckedContinuation { continuation in
      pending[id] = continuation
    }
  }

  func waiting(_ id: UUID) -> Bool { pending[id] != nil }

  func release(_ id: UUID, result: WorkspaceLoadResult) {
    pending[id]?.resume(returning: result)
    pending[id] = nil
  }
}

private actor ReviewDirectoryGate {
  private var pending: [CheckedContinuation<[WorkspaceRepositoryEntry], Never>] = []

  func load() async -> [WorkspaceRepositoryEntry] {
    await withCheckedContinuation { continuation in
      pending.append(continuation)
    }
  }

  func waiting() -> Bool { !pending.isEmpty }

  func release(_ entries: [WorkspaceRepositoryEntry]) {
    guard !pending.isEmpty else { return }
    pending.removeFirst().resume(returning: entries)
  }
}

@MainActor
struct WorkspaceReviewFixTests {
  private func root() throws -> URL {
    let value = FileManager.default.temporaryDirectory
      .appendingPathComponent("WebStudio-ReviewFix-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
    return value
  }

  private func configuration(id: UUID, name: String) -> WorkspaceConfiguration {
    WorkspaceConfiguration(
      workspaceID: id,
      name: name,
      resources: [],
      layout: .init(primary: .init(id: UUID(), resourceID: nil, isFocused: true), splitRatio: 0.5))
  }

  @Test func archivingFromAnotherWindowLeavesOwnerWindowUsable() async throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let repository = WorkspaceRepository(rootURL: root)
    let registry = WorkspaceRegistry(repository: repository)
    let caller = StudioModel(launchTerminalProcesses: false, registry: registry)
    let owner = StudioModel(launchTerminalProcesses: false, registry: registry)
    let callerID = caller.session.id
    owner.beginRenameGroup(owner.session.id)
    owner.renameSelectedGroup("待归档空间")
    let archivedID = owner.session.id
    let controller = try #require(registry.saveController(for: archivedID))
    #expect(await controller.saveNow())

    #expect(await caller.performArchiveWorkspace(archivedID))
    #expect(owner.session.id != archivedID)
    #expect(!owner.session.isClosed)
    owner.newTab()
    #expect(owner.tabs.count == 1)
    #expect(caller.session.id == callerID)
  }

  @Test func archivingOtherWindowWithRemainingSessionDoesNotCreateFallbackInCaller() async throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let repository = WorkspaceRepository(rootURL: root)
    let registry = WorkspaceRegistry(repository: repository)
    let caller = StudioModel(launchTerminalProcesses: false, registry: registry)
    let owner = StudioModel(launchTerminalProcesses: false, registry: registry)
    let callerID = caller.session.id
    let originalOwnerID = owner.session.id
    let remaining = try #require(owner.createWorkspace(name: "保留空间"))
    owner.selectWorkspace(originalOwnerID)
    owner.beginRenameGroup(originalOwnerID)
    owner.renameSelectedGroup("待归档空间")
    let archivedID = owner.session.id
    let controller = try #require(registry.saveController(for: archivedID))
    #expect(await controller.saveNow())

    #expect(await caller.performArchiveWorkspace(archivedID))
    #expect(owner.session.id == remaining)
    #expect(!owner.session.isClosed)
    #expect(caller.session.id == callerID)
  }

  @Test func closingWholeOwnerWindowDoesNotCreateFallbackWorkspace() async throws {
    let registry = WorkspaceRegistry()
    let owner = StudioModel(launchTerminalProcesses: false, registry: registry)
    let ownerID = owner.session.id
    #expect(await owner.windowCoordinator.closeAll())
    #expect(owner.windowCoordinator.activeWorkspaceID == nil)
    #expect(owner.session.id == ownerID)
    #expect(owner.session.isClosed)
    #expect(owner.groups.isEmpty)
  }

  @Test func creatingTabForUnloadedWorkspaceWaitsForOpenThenCreatesExactlyOne() async throws {
    let savedID = UUID()
    let saved = configuration(id: savedID, name: "延迟空间")
    let gate = ReviewLoadGate()
    let entry = WorkspaceRepositoryEntry.entry(.init(
      workspaceID: savedID, name: saved.name, archived: false, revision: 1,
      lastActivatedAt: saved.lastActivatedAt))
    let registry = WorkspaceRegistry(
      configurationLoader: { id in await gate.load(id) },
      directoryLoader: { [entry] })
    await registry.startRestoration()
    let model = StudioModel(launchTerminalProcesses: false, registry: registry)

    model.newTab(in: savedID)
    for _ in 0..<1_000 {
      if await gate.waiting(savedID) { break }
      await Task.yield()
    }
    #expect(await gate.waiting(savedID))
    await gate.release(savedID, result: .loaded(.init(configuration: saved, diagnostics: [])))
    for _ in 0..<1_000 {
      if model.session.id == savedID { break }
      await Task.yield()
    }
    #expect(model.session.id == savedID)
    #expect(model.tabs.count == 1)
    #expect(model.tabs.first?.groupID == savedID)
  }

  @Test func creatingTerminalForUnloadedWorkspaceWaitsForOpenThenCreatesExactlyOne() async throws {
    let savedID = UUID()
    let saved = configuration(id: savedID, name: "延迟终端空间")
    let gate = ReviewLoadGate()
    let entry = WorkspaceRepositoryEntry.entry(.init(
      workspaceID: savedID, name: saved.name, archived: false, revision: 1,
      lastActivatedAt: saved.lastActivatedAt))
    let registry = WorkspaceRegistry(
      configurationLoader: { id in await gate.load(id) },
      directoryLoader: { [entry] })
    await registry.startRestoration()
    let model = StudioModel(launchTerminalProcesses: false, registry: registry)

    model.newTerminal(in: savedID, directory: "/tmp")
    for _ in 0..<1_000 {
      if await gate.waiting(savedID) { break }
      await Task.yield()
    }
    #expect(await gate.waiting(savedID))
    await gate.release(savedID, result: .loaded(.init(configuration: saved, diagnostics: [])))
    for _ in 0..<1_000 {
      if model.session.id == savedID { break }
      await Task.yield()
    }
    #expect(model.session.id == savedID)
    #expect(model.tabs.count == 1)
    #expect(model.tabs.first?.groupID == savedID)
    #expect(model.tabs.first?.destination == .terminal(directory: "/tmp"))
  }

  @Test func supersededDelayedWorkspaceActionDoesNotCreateInStaleWorkspace() async throws {
    let firstID = UUID(); let secondID = UUID()
    let first = configuration(id: firstID, name: "先请求")
    let second = configuration(id: secondID, name: "后请求")
    let gate = ReviewLoadGate()
    let entries = [first, second].map {
      WorkspaceRepositoryEntry.entry(.init(
        workspaceID: $0.workspaceID, name: $0.name, archived: false, revision: 1,
        lastActivatedAt: $0.lastActivatedAt))
    }
    let registry = WorkspaceRegistry(
      configurationLoader: { id in await gate.load(id) },
      directoryLoader: { entries })
    await registry.startRestoration()
    let model = StudioModel(launchTerminalProcesses: false, registry: registry)

    model.newTab(in: firstID)
    for _ in 0..<1_000 {
      if await gate.waiting(firstID) { break }
      await Task.yield()
    }
    #expect(await gate.waiting(firstID))
    model.selectWorkspace(secondID)
    for _ in 0..<1_000 {
      if await gate.waiting(secondID) { break }
      await Task.yield()
    }
    #expect(await gate.waiting(secondID))
    await gate.release(firstID, result: .loaded(.init(configuration: first, diagnostics: [])))
    await gate.release(secondID, result: .loaded(.init(configuration: second, diagnostics: [])))
    for _ in 0..<1_000 {
      if model.session.id == secondID { break }
      await Task.yield()
    }
    #expect(model.session.id == secondID)
    #expect(model.tabs.isEmpty)
  }

  @Test func sameTurnWorkspaceSwitchSupersedesUnstartedAction() async throws {
    let savedID = UUID()
    let saved = configuration(id: savedID, name: "同步竞态空间")
    let gate = ReviewLoadGate()
    let entry = WorkspaceRepositoryEntry.entry(.init(
      workspaceID: savedID, name: saved.name, archived: false, revision: 1,
      lastActivatedAt: saved.lastActivatedAt))
    let registry = WorkspaceRegistry(
      configurationLoader: { id in await gate.load(id) },
      directoryLoader: { [entry] })
    await registry.startRestoration()
    let model = StudioModel(launchTerminalProcesses: false, registry: registry)
    let currentID = model.session.id

    model.newTab(in: savedID)
    model.selectWorkspace(currentID)
    for _ in 0..<1_000 { await Task.yield() }

    #expect(!(await gate.waiting(savedID)))
    #expect(model.session.id == currentID)
    #expect(model.tabs.isEmpty)
  }

  @Test func failedDelayedWorkspaceActionDoesNotCreateTerminal() async throws {
    let savedID = UUID()
    let saved = configuration(id: savedID, name: "失败空间")
    let entry = WorkspaceRepositoryEntry.entry(.init(
      workspaceID: savedID, name: saved.name, archived: false, revision: 1,
      lastActivatedAt: saved.lastActivatedAt))
    let registry = WorkspaceRegistry(
      configurationLoader: { id in throw WorkspaceRepositoryError.corrupt(id) },
      directoryLoader: { [entry] })
    await registry.startRestoration()
    let model = StudioModel(launchTerminalProcesses: false, registry: registry)
    let originalID = model.session.id

    model.newTerminal(in: savedID, directory: "/tmp")
    for _ in 0..<1_000 { await Task.yield() }
    #expect(model.session.id == originalID)
    #expect(model.tabs.isEmpty)
    #expect(registry.loadDiagnostics[savedID] == .corrupt(savedID))
  }

  @Test func blockedWorkspaceActionDoesNotStartLoadOrCreateTab() async throws {
    let savedID = UUID()
    let saved = configuration(id: savedID, name: "表单阻止空间")
    let gate = ReviewLoadGate()
    let entry = WorkspaceRepositoryEntry.entry(.init(
      workspaceID: savedID, name: saved.name, archived: false, revision: 1,
      lastActivatedAt: saved.lastActivatedAt))
    let registry = WorkspaceRegistry(
      configurationLoader: { id in await gate.load(id) },
      directoryLoader: { [entry] })
    await registry.startRestoration()
    let model = StudioModel(launchTerminalProcesses: false, registry: registry)
    model.openProviderSettings()

    model.newTab(in: savedID)
    for _ in 0..<100 { await Task.yield() }
    #expect(!(await gate.waiting(savedID)))
    #expect(model.tabs.isEmpty)
  }

  @Test func directoryScanDiagnosticsRemainAvailableForUiPresentation() async throws {
    let corruptID = UUID()
    let unknownID = UUID()
    let entries: [WorkspaceRepositoryEntry] = [
      .diagnostic(corruptID, .corrupt(corruptID)),
      .diagnostic(unknownID, .unknownSchema(unknownID, 99)),
    ]
    let registry = WorkspaceRegistry(directoryLoader: { entries })
    await registry.startRestoration()

    #expect(registry.diagnostics.contains(.corrupt(corruptID)))
    #expect(registry.diagnostics.contains(.unknownSchema(unknownID, 99)))
    #expect(registry.loadDiagnostics.isEmpty)
  }

  @Test func concurrentRescanCoalescesAndFreshScanReplacesDiagnostics() async throws {
    let badID = UUID()
    let goodID = UUID()
    let good = configuration(id: goodID, name: "新配置")
    let gate = ReviewDirectoryGate()
    let registry = WorkspaceRegistry(directoryLoader: { await gate.load() })

    async let first = registry.rescanDirectory()
    for _ in 0..<1_000 {
      if await gate.waiting() { break }
      await Task.yield()
    }
    #expect(await gate.waiting())
    async let coalesced = registry.rescanDirectory()
    await gate.release([.diagnostic(badID, .corrupt(badID))])
    await first
    await coalesced
    #expect(registry.diagnostics.contains(.corrupt(badID)))

    async let refreshed = registry.rescanDirectory()
    for _ in 0..<1_000 {
      if await gate.waiting() { break }
      await Task.yield()
    }
    await gate.release([.entry(.init(
      workspaceID: goodID, name: good.name, archived: false, revision: 1,
      lastActivatedAt: good.lastActivatedAt))])
    await refreshed
    #expect(!registry.diagnostics.contains(.corrupt(badID)))
    #expect(registry.entries.contains { $0.id == goodID })
  }

  @Test func rescanLeavesCorruptConfigurationBytesUntouched() async throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let fileURL = root.appendingPathComponent(id.uuidString + ".json")
    let original = Data("{\"schemaVersion\":99,\"broken\":".utf8)
    try original.write(to: fileURL)
    let repository = WorkspaceRepository(rootURL: root)
    let registry = WorkspaceRegistry(repository: repository)

    await registry.rescanDirectory()
    #expect(registry.diagnostics.contains(.corrupt(id)))
    #expect(try Data(contentsOf: fileURL) == original)
    #expect(registry.diagnosticEntries.first?.fileURL == fileURL)
  }
}
