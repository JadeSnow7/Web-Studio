import Foundation
import Testing

@testable import Web_Studio

@MainActor
struct WorkspaceSaveControllerTests {
  private func root() throws -> URL {
    let value = FileManager.default.temporaryDirectory
      .appendingPathComponent("WebStudio-P2c-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
    return value
  }

  @Test func temporarySessionDoesNotWrite() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = WorkspaceSession(launchTerminalProcesses: false)
    let controller = WorkspaceSaveController(
      session: session, repository: WorkspaceRepository(rootURL: root),
      debounce: .milliseconds(1))
    controller.markConfigurationChanged()
    #expect(await controller.flush())
    #expect(
      (try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
        .isEmpty)
  }

  @Test func saveGenerationAndConfigurationRoundTrip() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = WorkspaceSession(
      name: "Saved", isTemporary: false,
      launchTerminalProcesses: false)
    let controller = WorkspaceSaveController(
      session: session, repository: WorkspaceRepository(rootURL: root),
      debounce: .milliseconds(1))
    session.layout = WorkspaceLayout(
      primary: PaneState(resourceID: nil, isFocused: true),
      splitRatio: 0.3)
    controller.markConfigurationChanged()
    #expect(await controller.flush())
    guard case .saved(let generation, let revision) = controller.state else {
      Issue.record("expected saved state")
      return
    }
    #expect(generation == 1)
    #expect(revision == 1)
    let loaded = try await WorkspaceRepository(rootURL: root).load(id: session.id)
    guard case .loaded(let envelope) = loaded else {
      Issue.record("expected loaded configuration")
      return
    }
    #expect(envelope.configuration.name == "Saved")
    #expect(envelope.configuration.layout.splitRatio == 0.3)
  }

  @Test func failedSaveKeepsDirtyConfigurationForRetry() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = WorkspaceSession(
      name: "Saved", isTemporary: false,
      launchTerminalProcesses: false)
    let repository = WorkspaceRepository(rootURL: root, faults: [.beforeWrite])
    let controller = WorkspaceSaveController(session: session, repository: repository)
    controller.markConfigurationChanged()
    #expect(!(await controller.flush()))
    guard case .failed(let generation, _) = controller.state else {
      Issue.record("expected failed state")
      return
    }
    #expect(generation == 1)
  }

  @Test func configurationRestoreKeepsFixedIDsAndDoesNotStartResources() throws {
    let resourceIDs = (0..<4).map { _ in UUID() }
    let configuration = WorkspaceConfiguration(
      workspaceID: UUID(), revision: 7, name: "Restored", directory: "/tmp",
      archived: true,
      resources: [
        .init(id: resourceIDs[0], destination: .blank, customTitle: "Blank", order: 0),
        .init(id: resourceIDs[1], destination: .web(url: "https://example.com"), customTitle: nil, order: 1),
        .init(id: resourceIDs[2], destination: .terminal(directory: "/tmp"), customTitle: "Shell", order: 2),
        .init(
          id: resourceIDs[3], destination: .ssh(host: "example.com", user: "dev", port: 22), customTitle: "SSH",
          order: 3),
      ],
      pinnedDestinations: [
        .init(id: UUID(), title: "Pinned", destination: .blank)
      ],
      layout: .init(
        primary: .init(id: UUID(), resourceID: resourceIDs[0], isFocused: true),
        secondary: .init(id: UUID(), resourceID: resourceIDs[1], isFocused: false),
        splitRatio: 0.35),
      panelPreferences: .init(tabStripVisible: false, agentsVisible: true),
      lastActivatedAt: Date(timeIntervalSince1970: 42))
    let session = WorkspaceSession(configuration: configuration)
    #expect(session.resourceStore.resources.map { $0.id } == resourceIDs)
    #expect(session.resourceStore.terminalFactoryCreationCount == 0)
    #expect(session.resourceStore.activeRuntimeCount == 0)
    #expect(session.directory == "/tmp")
    #expect(session.archived)
    #expect(session.isTemporary == false)
    #expect(session.pinnedDestinations.count == 1)
    #expect(session.exportConfiguration(revision: 7) == configuration)
  }

  @Test func automaticObservationSerializesGenerationsWithLatestName() async throws {
    let gate = ControlledWriter()
    let temporaryRoot = try root()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let session = WorkspaceSession(
      name: "Old", isTemporary: false,
      launchTerminalProcesses: false)
    let controller = WorkspaceSaveController(
      session: session, repository: WorkspaceRepository(rootURL: temporaryRoot),
      debounce: .seconds(60),
      writer: { configuration, expected in
        try await gate.write(configuration, expectedRevision: expected)
      })
    let first = Task { await controller.flush() }
    while true {
      let count = await gate.expectedRevisions.count
      let waiting = await gate.isWaiting
      if count >= 1 && waiting { break }
      await Task.yield()
    }
    session.name = "New"
    await Task.yield()
    let second = Task { await controller.flush() }
    await gate.releaseFirst()
    _ = await first.value
    _ = await second.value
    #expect(await gate.expectedRevisions == [nil, 1])
    #expect(await gate.names == ["Old", "New"])
  }

  @Test func discardWaitsForFirstWriteAndPreventsLaterWrite() async throws {
    let gate = ControlledWriter()
    let temporaryRoot = try root()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let session = WorkspaceSession(
      name: "Old", isTemporary: false,
      launchTerminalProcesses: false)
    let controller = WorkspaceSaveController(
      session: session, repository: WorkspaceRepository(rootURL: temporaryRoot),
      debounce: .seconds(60),
      writer: { configuration, expected in
        try await gate.write(configuration, expectedRevision: expected)
      })
    let first = Task { await controller.flush() }
    while true {
      let count = await gate.expectedRevisions.count
      let waiting = await gate.isWaiting
      if count >= 1 && waiting { break }
      await Task.yield()
    }
    session.name = "Discarded"
    let discarded = Task { await controller.discardPendingChanges() }
    await gate.releaseFirst()
    let saved = await discarded.value
    _ = await first.value
    #expect(saved?.name == "Old")
    #expect(await gate.expectedRevisions.count == 1)
    #expect(session.name == "Discarded")
  }

  @Test func propertyChangeAutomaticallyFlushesAfterDebounce() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = WorkspaceSession(
      name: "Old", isTemporary: false,
      launchTerminalProcesses: false)
    let repository = WorkspaceRepository(rootURL: root)
    let controller = WorkspaceSaveController(
      session: session, repository: repository, debounce: .milliseconds(5))
    session.name = "Auto Saved"
    for _ in 0..<100 {
      if case .saved = controller.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .saved = controller.state else {
      Issue.record("debounced observation did not save")
      return
    }
    guard case .loaded(let envelope) = try await repository.load(id: session.id) else {
      Issue.record("expected saved file")
      return
    }
    #expect(envelope.configuration.name == "Auto Saved")
  }

  @Test func initialRevisionIsPassedToWriter() async throws {
    let temporaryRoot = try root()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let session = WorkspaceSession(
      name: "Old", isTemporary: false,
      launchTerminalProcesses: false)
    let initial = session.exportConfiguration(revision: 7)
    let writer = RevisionWriter()
    let controller = WorkspaceSaveController(
      session: session, repository: WorkspaceRepository(rootURL: temporaryRoot),
      initialSavedConfiguration: initial, debounce: .milliseconds(5),
      writer: { configuration, expected in
        try await writer.write(configuration, expectedRevision: expected)
      })
    session.name = "New"
    for _ in 0..<100 {
      if await writer.count > 0 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await writer.expected == [7])
    #expect(controller.state == .saved(generation: 1, revision: 8))
  }

  @Test func runtimeAndTitleChangesDoNotSaveConfiguration() async throws {
    let temporaryRoot = try root()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let session = WorkspaceSession(
      name: "Stable", isTemporary: false,
      launchTerminalProcesses: false)
    let id = session.resourceStore.registerWeb(groupID: session.id)
    let initial = session.exportConfiguration(revision: 1)
    let writer = RevisionWriter()
    let controller = WorkspaceSaveController(
      session: session, repository: WorkspaceRepository(rootURL: temporaryRoot),
      initialSavedConfiguration: initial, debounce: .milliseconds(5),
      writer: { configuration, expected in
        try await writer.write(configuration, expectedRevision: expected)
      })
    session.resourceStore.updateTitle(resourceID: id, title: "Live title")
    if var record = session.resourceStore.records[id] {
      record.lifecycle = .failed
      record.errorMessage = "runtime diagnostic"
      record.runtimeInstanceID = UUID()
      session.resourceStore.update(record)
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await writer.count == 0)
    _ = controller
  }

  @Test func failedSaveDoesNotAutomaticallyRetryAfterNewEdit() async throws {
    let temporaryRoot = try root()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let session = WorkspaceSession(
      name: "Old", isTemporary: false,
      launchTerminalProcesses: false)
    let writer = FailableWriter()
    let controller = WorkspaceSaveController(
      session: session, repository: WorkspaceRepository(rootURL: temporaryRoot),
      debounce: .milliseconds(5),
      writer: { configuration, expected in
        try await writer.write(configuration, expectedRevision: expected)
      })
    session.name = "First"
    for _ in 0..<100 {
      if case .failed = controller.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .failed(_, let firstMessage) = controller.state else {
      Issue.record("expected initial failure")
      return
    }
    session.name = "Second"
    try await Task.sleep(for: .milliseconds(50))
    guard case .failed(_, let secondMessage) = controller.state else {
      Issue.record("failure was cleared or retried automatically")
      return
    }
    #expect(await writer.count == 1)
    #expect(secondMessage == firstMessage)
    #expect(await controller.retry())
    #expect(await writer.count == 2)
    guard case .saved(_, let revision) = controller.state else {
      Issue.record("expected retry success")
      return
    }
    #expect(revision == 1)
  }
}

private actor ControlledWriter {
  var expectedRevisions: [Int?] = []
  var names: [String] = []
  var firstContinuation: CheckedContinuation<Void, Never>?
  func write(
    _ configuration: WorkspaceConfiguration,
    expectedRevision: Int?
  ) async throws -> WorkspaceConfiguration {
    expectedRevisions.append(expectedRevision)
    names.append(configuration.name)
    if expectedRevisions.count == 1 {
      await withCheckedContinuation { continuation in
        firstContinuation = continuation
      }
    }
    var result = configuration
    result.revision = (expectedRevision ?? 0) + 1
    return result
  }
  func releaseFirst() {
    firstContinuation?.resume()
    firstContinuation = nil
  }
  var isWaiting: Bool { firstContinuation != nil }
}

private actor RevisionWriter {
  var expected: [Int?] = []
  var count = 0
  func write(
    _ configuration: WorkspaceConfiguration,
    expectedRevision: Int?
  ) async throws -> WorkspaceConfiguration {
    count += 1
    expected.append(expectedRevision)
    var result = configuration
    result.revision = (expectedRevision ?? 0) + 1
    return result
  }
}

private actor FailableWriter {
  var count = 0
  func write(
    _ configuration: WorkspaceConfiguration,
    expectedRevision: Int?
  ) async throws -> WorkspaceConfiguration {
    count += 1
    if count == 1 {
      throw WorkspaceRepositoryError.injectedFault(.beforeWrite)
    }
    var result = configuration
    result.revision = (expectedRevision ?? 0) + 1
    return result
  }
}
