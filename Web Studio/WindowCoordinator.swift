import AppKit
import Combine
import Foundation

struct WorkspaceCloseSummary: Equatable, Sendable {
  struct Entry: Equatable, Sendable {
    let workspaceID: UUID
    let name: String
    let runningTerminals: Int
    let requestingAgents: Int
    let isTemporary: Bool
  }
  let entries: [Entry]
}
@MainActor
final class WindowCoordinator: ObservableObject {
  let registry: WorkspaceRegistry
  let panels = PanelCoordinator()
  weak var window: NSWindow? { didSet { registry.bindWindow(window, to: self) } }
  @Published private(set) var loadedSessions: [UUID: WorkspaceSession] = [:]
  @Published private(set) var activeWorkspaceID: UUID?
  private(set) var closingTask: Task<Bool, Never>?
  private var closingWorkspaceTasks: [UUID: Task<Bool, Never>] = [:]
  private var workspaceLoadToken = 0
  @Published private(set) var isClosing = false
  @Published private(set) var isPreparing = false
  private var isClosed = false
  var canAcceptWorkspace: Bool { !isClosing && !isClosed }
  func beginClosePreparation() { isClosing = true }
  func cancelClosePreparation() { if !isClosed { isClosing = false } }
  func issueWorkspaceLoadToken() -> Int {
    workspaceLoadToken += 1
    return workspaceLoadToken
  }
  func acceptsWorkspaceLoadToken(_ token: Int) -> Bool {
    workspaceLoadToken == token
  }
  var onActivateWindow: ((NSWindow) -> Void)?
  var onActiveSessionChanged: ((WorkspaceSession?) -> Void)?
  var shouldSelectWorkspace: ((UUID) -> Bool)?
  var activeSession: WorkspaceSession? { activeWorkspaceID.flatMap { loadedSessions[$0] } }
  init(registry: WorkspaceRegistry, window: NSWindow? = nil) {
    self.registry = registry
    self.window = window
  }
  @discardableResult
  func createWorkspace(
    name: String = "临时空间", isTemporary: Bool = true,
    launchTerminalProcesses: Bool = true
  ) -> WorkspaceSession? {
    _ = issueWorkspaceLoadToken()
    guard !isClosing, !isClosed else { return nil }
    let session = registry.create(
      name: name, isTemporary: isTemporary,
      launchTerminalProcesses: launchTerminalProcesses)
    guard case .opened(let opened) = open(session.id) else {
      registry.remove(session.id)
      return nil
    }
    return opened
  }

  @discardableResult
  func open(_ id: UUID) -> WorkspaceOpenResult {
    _ = issueWorkspaceLoadToken()
    guard !isClosing, !isClosed, let session = registry.session(for: id) else {
      return .unavailable
    }
    if let owner = registry.coordinator(for: id), owner !== self {
      if let window = owner.window ?? registry.location(for: id)?.window {
        onActivateWindow?(window)
      }
      _ = owner.select(id)
      return .locatedExistingWindow(workspaceID: id)
    }
    guard shouldSelectWorkspace?(id) ?? true else { return .unavailable }
    if loadedSessions[id] == nil {
      guard registry.attach(session, to: self, window: window) else {
        return .unavailable
      }
      loadedSessions[id] = session
    }
    setActive(id)
    return .opened(session)
  }

  @discardableResult
  func select(_ id: UUID) -> WorkspaceSession? {
    _ = issueWorkspaceLoadToken()
    guard !isClosing, !isClosed, let session = loadedSessions[id],
      !session.isClosed,
      shouldSelectWorkspace?(id) ?? true
    else { return nil }
    setActive(id)
    return session
  }

  private func setActive(_ id: UUID?, recordActivation: Bool = true) {
    activeWorkspaceID = id
    if recordActivation, let id { registry.recordActivation(id) }
    onActiveSessionChanged?(activeSession)
  }
  func closeSummary() -> WorkspaceCloseSummary {
    let entries: [WorkspaceCloseSummary.Entry] = loadedSessions.values.map { session in
      let requestingAgents: Int
      requestingAgents = session.agentController.isRequesting ? 1 : 0
      return WorkspaceCloseSummary.Entry(
        workspaceID: session.id,
        name: session.name,
        runningTerminals: session.resourceStore.liveTerminalCount,
        requestingAgents: requestingAgents,
        isTemporary: session.isTemporary
      )
    }.sorted {
      $0.name == $1.name
        ? $0.workspaceID.uuidString < $1.workspaceID.uuidString
        : $0.name < $1.name
    }
    return WorkspaceCloseSummary(entries: entries)
  }
  @discardableResult
  func closeWorkspace(_ id: UUID, resolver: WorkspaceCloseResolver? = nil) async -> Bool {
    _ = issueWorkspaceLoadToken()
    if let task = closingWorkspaceTasks[id] {
      return await task.value
    }
    guard !isClosing, !isClosed, let session = loadedSessions[id] else { return false }
    isClosing = true
    isPreparing = true
    let task = Task<Bool, Never> { @MainActor [weak self] in
      guard let self else { return false }
      let preparation = await self.registry.prepareSessionClose(session, resolver: resolver)
      guard preparation.accepted else {
        self.isPreparing = false
        self.isClosing = false
        return false
      }
      self.isPreparing = false
      let result = await self.cleanupWorkspace(
        id, discard: preparation.discard, recordActivation: true, trackTask: false)
      self.isClosing = false
      return result
    }
    closingWorkspaceTasks[id] = task
    let result = await task.value
    closingWorkspaceTasks[id] = nil
    return result
  }

  private func cleanupWorkspace(
    _ id: UUID, discard: Bool, recordActivation: Bool = false, trackTask: Bool = true
  ) async -> Bool {
    guard registry.beginClosing(id) else { return false }
    let task = Task<Bool, Never> { @MainActor [weak self] in
      guard let self, let session = self.loadedSessions[id] else { return false }
      if discard { _ = await self.registry.saveController(for: id)?.discardPendingChanges() }
      self.registry.saveController(for: id)?.stopObserving()
      await session.close()
      self.registry.detach(id, from: self)
      self.registry.releaseSession(id, preservingDirectory: true)
      self.loadedSessions.removeValue(forKey: id)
      if self.activeWorkspaceID == id {
        self.setActive(
          self.loadedSessions.keys.sorted { $0.uuidString < $1.uuidString }.first,
          recordActivation: recordActivation)
      }
      return true
    }
    if trackTask { closingWorkspaceTasks[id] = task }
    let result = await task.value
    if trackTask { closingWorkspaceTasks[id] = nil }
    return result
  }
  @discardableResult
  func closeAll(resolver: WorkspaceCloseResolver? = nil) async -> Bool {
    _ = issueWorkspaceLoadToken()
    if let t = closingTask {
      return await t.value
    }
    guard !isClosing, !isClosed else { return false }
    isClosing = true
    let t = Task<Bool, Never> { @MainActor [weak self] in
      guard let self else { return false }
      let sessions = self.loadedSessions.values.sorted { $0.id.uuidString < $1.id.uuidString }
      guard let discards = await self.registry.prepareSessionsClose(sessions, resolver: resolver) else {
        self.isClosing = false
        return false
      }
      for id in self.loadedSessions.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
        guard await self.cleanupWorkspace(
          id, discard: discards.contains(id), recordActivation: false, trackTask: false) else {
          self.isClosing = false
          return false
        }
      }
      self.loadedSessions.removeAll()
      self.setActive(nil)
      self.isClosing = false
      self.isClosed = true
      return true
    }
    closingTask = t
    await t.value
    closingTask = nil
    return isClosed
  }

  @discardableResult
  func cleanupPreparedWorkspaces(discardIDs: Set<UUID>) async -> Bool {
    guard isClosing else { return false }
    for id in loadedSessions.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard await cleanupWorkspace(id, discard: discardIDs.contains(id)) else {
        isClosing = false
        return false
      }
    }
    loadedSessions.removeAll()
    setActive(nil, recordActivation: false)
    isClosing = false
    isClosed = true
    return true
  }

  @discardableResult
  func cleanupPreparedWorkspace(_ id: UUID, discard: Bool = false) async -> Bool {
    guard isClosing else { return false }
    let result = await cleanupWorkspace(
      id, discard: discard, recordActivation: true, trackTask: false)
    isClosing = false
    // A single archive can empty this window while the window itself remains open.
    // Notify the model after the closing gate is lifted so it can create its normal
    // temporary fallback. closeAll marks the coordinator closed and never reaches here.
    if result, !isClosed { onActiveSessionChanged?(activeSession) }
    return result
  }
  func withOwnedWorkspace<T>(_ id: UUID, _ body: (WorkspaceSession) -> T) -> T? {
    guard !isClosing, let session = loadedSessions[id], !session.isClosed else { return nil }
    return body(session)
  }

  func acceptCallback<T>(
    _ id: UUID, resourceID: UUID? = nil,
    _ body: (WorkspaceSession) -> T
  ) -> T? {
    guard !isClosing, let session = loadedSessions[id], !session.isClosed,
      resourceID == nil || session.resourceStore.records[resourceID!] != nil
    else {
      return nil
    }
    return body(session)
  }
}
