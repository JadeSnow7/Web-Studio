import Foundation
import Testing
@testable import Web_Studio

@MainActor
struct WorkspaceClosePreparationTests {
  actor WriterProbe {
    let repository: WorkspaceRepository
    var calls = 0
    var fail = false
    var blockedID: UUID?
    var waiter: CheckedContinuation<Void, Never>?
    init(repository: WorkspaceRepository) { self.repository = repository }
    func write(_ configuration: WorkspaceConfiguration, expected: Int?) async throws -> WorkspaceConfiguration {
      calls += 1
      if fail { throw WorkspaceRepositoryError.permissionFailure(configuration.workspaceID) }
      if blockedID == configuration.workspaceID {
        await withCheckedContinuation { continuation in waiter = continuation }
      }
      let result = try await repository.save(configuration, expectedRevision: expected)
      guard case let .saved(envelope) = result else { throw WorkspaceRepositoryError.corrupt(configuration.workspaceID) }
      return envelope.configuration
    }
    func count() -> Int { calls }
    func setFail(_ value: Bool) { fail = value }
    func block(_ id: UUID) { blockedID = id }
    func release() {
      blockedID = nil
      waiter?.resume()
      waiter = nil
    }
    func isWaiting() -> Bool { waiter != nil }
  }

  private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("WebStudio-Close-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeRegistry() throws -> (WorkspaceRegistry, WriterProbe, URL) {
    let url = try root()
    let repository = WorkspaceRepository(rootURL: url)
    let probe = WriterProbe(repository: repository)
    let writer: WorkspaceSaveController.Writer = { configuration, expected in
      try await probe.write(configuration, expected: expected)
    }
    return (WorkspaceRegistry(repository: repository, saveWriter: writer), probe, url)
  }

  @Test func failedCancelKeepsSessionUsable() async throws {
    let (registry, probe, url) = try makeRegistry()
    defer { try? FileManager.default.removeItem(at: url) }
    await probe.setFail(true)
    let session = registry.create(name: "A", isTemporary: false, launchTerminalProcesses: false)
    let resolver: WorkspaceCloseResolver = { _, _ in .cancel }
    #expect(await registry.close(session.id, resolver: resolver) == false)
    #expect(registry.session(for: session.id) === session)
    session.name = "still open"
    await probe.setFail(false)
    #expect(await registry.saveController(for: session.id)?.saveNow() == true)
    #expect(await registry.close(session.id, resolver: resolver) == true)
  }

  @Test func discardThenCancelKeepsOtherWindowAlive() async throws {
    let (registry, probe, url) = try makeRegistry()
    defer { try? FileManager.default.removeItem(at: url) }
    await probe.setFail(true)
    let a = WorkspaceSession(name: "A", isTemporary: false, launchTerminalProcesses: false,
                             providerSettings: registry.providerSettings)
    let b = WorkspaceSession(name: "B", isTemporary: false, launchTerminalProcesses: false,
                             providerSettings: registry.providerSettings)
    #expect(registry.add(a)); #expect(registry.add(b))
    let first = WindowCoordinator(registry: registry); let second = WindowCoordinator(registry: registry)
    _ = first.open(a.id); _ = second.open(b.id)
    var resolverCalls = 0
    let resolver: WorkspaceCloseResolver = { _, _ in
      resolverCalls += 1
      return resolverCalls == 1 ? .discard : .cancel
    }
    #expect(await registry.closeAll(resolver: resolver) == false)
    #expect(resolverCalls == 2)
    #expect(registry.session(for: a.id) === a); #expect(registry.session(for: b.id) === b)
    await probe.setFail(false)
    #expect(await registry.saveController(for: a.id)?.saveNow() == true)
  }

  @Test func twoWindowCancelLeavesBothLoaded() async throws {
    let (registry, probe, url) = try makeRegistry()
    defer { try? FileManager.default.removeItem(at: url) }
    await probe.setFail(true)
    let a = registry.create(name: "A", isTemporary: false, launchTerminalProcesses: false)
    let b = registry.create(name: "B", isTemporary: false, launchTerminalProcesses: false)
    let one = WindowCoordinator(registry: registry); let two = WindowCoordinator(registry: registry)
    _ = one.open(a.id); _ = two.open(b.id)
    let resolver: WorkspaceCloseResolver = { _, _ in .cancel }
    #expect(await registry.closeAll(resolver: resolver) == false)
    #expect(one.loadedSessions.count == 1); #expect(two.loadedSessions.count == 1)
  }

  @Test func unownedFailureDoesNotCloseOwnedSession() async throws {
    let (registry, probe, url) = try makeRegistry()
    defer { try? FileManager.default.removeItem(at: url) }
    let owned = registry.create(name: "owned", isTemporary: false, launchTerminalProcesses: false)
    let unowned = registry.create(name: "unowned", isTemporary: false, launchTerminalProcesses: false)
    let coordinator = WindowCoordinator(registry: registry); _ = coordinator.open(owned.id)
    await probe.setFail(true)
    #expect(await registry.closeAll(resolver: { _, _ in .cancel }) == false)
    #expect(registry.session(for: owned.id) === owned); #expect(registry.session(for: unowned.id) === unowned)
  }

  @Test func duplicateCloseReturnsSameCleanupOutcome() async throws {
    let (registry, probe, url) = try makeRegistry()
    defer { try? FileManager.default.removeItem(at: url) }
    let session = registry.create(name: "A", isTemporary: false, launchTerminalProcesses: false)
    let first = Task { await registry.close(session.id) }
    let second = Task { await registry.close(session.id) }
    let firstResult = await first.value
    let secondResult = await second.value
    #expect(firstResult == secondResult)
  }

  @Test func failedFirstSaveDiscardLeavesNoGhostDirectory() async throws {
    let (registry, probe, url) = try makeRegistry()
    defer { try? FileManager.default.removeItem(at: url) }
    await probe.setFail(true)
    let session = registry.create(name: "never saved", isTemporary: false, launchTerminalProcesses: false)
    #expect(await registry.close(session.id, resolver: { _, _ in .discard }) == true)
    #expect(!registry.entries.contains { $0.id == session.id })
  }

  @Test func archiveLoadedUsesLatestNameAndCloses() async throws {
    let (registry, probe, url) = try makeRegistry()
    defer { try? FileManager.default.removeItem(at: url) }
    let session = registry.create(name: "old", isTemporary: false, launchTerminalProcesses: false)
    session.name = "latest"
    #expect(await registry.archive(session.id))
    #expect(registry.session(for: session.id) == nil)
    #expect(registry.archivedEntries.first { $0.id == session.id }?.name == "latest")
    #expect(await registry.unarchive(session.id))
  }

  @Test func archiveKeepsOtherLoadedSession() async throws {
    let (registry, probe, url) = try makeRegistry()
    defer { try? FileManager.default.removeItem(at: url) }
    let target = registry.create(name: "target", isTemporary: false, launchTerminalProcesses: false)
    let other = registry.create(name: "other", isTemporary: false, launchTerminalProcesses: false)
    let owner = WindowCoordinator(registry: registry)
    _ = owner.open(target.id)
    _ = owner.open(other.id)
    target.name = "latest"
    #expect(await registry.archive(target.id))
    #expect(registry.session(for: target.id) == nil)
    #expect(owner.select(other.id) === other)
    #expect(owner.loadedSessions.count == 1)
    #expect(registry.archivedEntries.first { $0.id == target.id }?.name == "latest")
    let repository = WorkspaceRepository(rootURL: url)
    guard let result = try? await repository.load(id: target.id),
          case let .loaded(envelope) = result else {
      Issue.record("expected archived disk entry")
      return
    }
    #expect(envelope.configuration.archived)
    #expect(envelope.configuration.name == "latest")
    _ = probe
  }

  @Test func temporaryArchiveRejectedThenRenameSaves() async throws {
    let (registry, probe, url) = try makeRegistry()
    defer { try? FileManager.default.removeItem(at: url) }
    let session = registry.create(launchTerminalProcesses: false)
    #expect(await registry.archive(session.id) == false)
    #expect(registry.rename(session.id, name: "named"))
    await probe.setFail(false)
    #expect(await registry.saveController(for: session.id)?.saveNow() == true)
  }

  @Test func archiveWriteFailureKeepsSessionUsable() async throws {
    let (registry, probe, url) = try makeRegistry()
    defer { try? FileManager.default.removeItem(at: url) }
    let session = registry.create(name: "A", isTemporary: false, launchTerminalProcesses: false)
    let owner = WindowCoordinator(registry: registry); _ = owner.open(session.id)
    await probe.setFail(true)
    #expect(await registry.archive(session.id) == false)
    #expect(session.archived == false)
    #expect(owner.canAcceptWorkspace)
    #expect(registry.session(for: session.id) === session)
  }

  @Test func duplicateCloseWaitsForSingleResourceCleanup() async throws {
    let (registry, _, url) = try makeRegistry()
    defer { try? FileManager.default.removeItem(at: url) }
    let session = registry.create(name: "A", isTemporary: false, launchTerminalProcesses: false)
    _ = session.resourceStore.registerLocalTerminal(
      groupID: session.id,
      directory: FileManager.default.temporaryDirectory.path)
    actor Gate { var count = 0; var waiter: CheckedContinuation<Void, Never>?
      func wait() async { count += 1; await withCheckedContinuation { waiter = $0 } }
      func release() { waiter?.resume(); waiter = nil }
      func value() -> Int { count }
    }
    let gate = Gate(); session.resourceStore.closeAndWaitHook = { await gate.wait() }
    let first = Task { await registry.close(session.id) }
    while await gate.value() == 0 { await Task.yield() }
    let second = Task { await registry.close(session.id) }
    await Task.yield()
    await gate.release()
    let firstResult = await first.value; let secondResult = await second.value
    #expect(firstResult); #expect(secondResult); #expect(await gate.value() == 1)
  }

  @Test func editDuringOtherSaveRemainsDirtyForNextFlush() async throws {
    let (registry, probe, url) = try makeRegistry()
    defer { try? FileManager.default.removeItem(at: url) }
    let first = UUID(); let second = UUID()
    let aID = first.uuidString < second.uuidString ? first : second
    let bID = aID == first ? second : first
    let a = WorkspaceSession(id: aID, name: "A", isTemporary: false,
                             launchTerminalProcesses: false, providerSettings: registry.providerSettings)
    let b = WorkspaceSession(id: bID, name: "B", isTemporary: false,
                             launchTerminalProcesses: false, providerSettings: registry.providerSettings)
    #expect(registry.add(a)); #expect(registry.add(b))
    await probe.block(b.id)
    a.name = "A2"; b.name = "B2"
    let closeTask = Task { await registry.closeAll(resolver: { _, _ in .cancel }) }
    while !(await probe.isWaiting()) { await Task.yield() }
    a.name = "A3"
    await probe.release()
    #expect(await closeTask.value == true)
    let repository = WorkspaceRepository(rootURL: url)
    guard let result = try? await repository.load(id: a.id),
          case let .loaded(envelope) = result else {
      Issue.record("expected saved A")
      return
    }
    #expect(envelope.configuration.name == "A3")
    #expect(await probe.count() >= 2)
  }
}
