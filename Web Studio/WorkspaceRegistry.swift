import AppKit
import Combine
import Foundation

enum WorkspaceSaveFailureChoice: Sendable {
  case retry
  case cancel
  case discard
}

typealias WorkspaceCloseResolver =
  @MainActor (WorkspaceSession, String) async -> WorkspaceSaveFailureChoice

enum WorkspaceCopyError: Error, LocalizedError, Sendable, Equatable {
  case sourceUnavailable
  case targetUnavailable
  case archivedWorkspace
  case resourceUnavailable
  case conflict
  case saveFailed(String)
  var errorDescription: String? {
    switch self {
    case .sourceUnavailable: return "源空间不可用"
    case .targetUnavailable: return "目标空间不可用"
    case .archivedWorkspace: return "空间已归档"
    case .resourceUnavailable: return "资源不可用"
    case .conflict: return "目标空间已发生变化"
    case .saveFailed(let message): return message
    }
  }
}

struct WorkspaceDirectoryEntry: Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let isTemporary: Bool
  let archived: Bool
  let lastActivatedAt: Date?
  init(id: UUID, name: String, isTemporary: Bool, archived: Bool = false,
       lastActivatedAt: Date? = nil) {
    self.id = id
    self.name = name
    self.isTemporary = isTemporary
    self.archived = archived
    self.lastActivatedAt = lastActivatedAt
  }
}

struct WorkspaceDiagnostic: Identifiable, Equatable, Sendable {
  let workspaceID: UUID?
  let error: WorkspaceRepositoryError
  let fileURL: URL?

  var id: String {
    "\(workspaceID?.uuidString ?? "global"):\(String(describing: error))"
  }

  var title: String {
    switch error {
    case .corrupt: return "配置损坏"
    case .unknownSchema(_, let version): return "不支持的配置版本（\(version)）"
    case .notFound: return "配置不存在"
    default: return "配置读取失败"
    }
  }

  var detail: String {
    if let workspaceID { return "空间 \(workspaceID.uuidString) · \(title)" }
    return title
  }
}
enum WorkspaceOpenResult: Equatable {
  case opened(WorkspaceSession)
  case locatedExistingWindow(workspaceID: UUID)
  case unavailable
  static func == (l: Self, r: Self) -> Bool {
    switch (l, r) {
    case (.opened(let a), .opened(let b)): return a.id == b.id
    case (.locatedExistingWindow(let a), .locatedExistingWindow(let b)): return a == b
    case (.unavailable, .unavailable): return true
    default: return false
    }
  }
}

private extension WorkspaceLoadResult {
  var configuration: WorkspaceConfiguration? {
    switch self {
    case .loaded(let envelope), .recoveredFromBackup(let envelope):
      return envelope.configuration
    }
  }
  var diagnostics: [WorkspaceConfigurationDiagnostic] {
    switch self {
    case .loaded(let envelope), .recoveredFromBackup(let envelope):
      return envelope.diagnostics
    }
  }
}

private func configurationProjection(_ configuration: WorkspaceConfiguration)
  -> WorkspaceConfiguration {
  var value = configuration
  value.revision = 0
  return value
}

@MainActor final class WorkspaceRegistry: ObservableObject {
  final class Location {
    weak var window: NSWindow?
    weak var coordinator: WindowCoordinator?
    init(window: NSWindow?, coordinator: WindowCoordinator?) {
      self.window = window
      self.coordinator = coordinator
    }
  }
  private final class WeakSession {
    weak var value: WorkspaceSession?
    init(_ value: WorkspaceSession) { self.value = value }
  }
  private var directory: [UUID: WorkspaceDirectoryEntry] = [:]
  private var sessionsByID: [UUID: WeakSession] = [:]
  private var locations: [UUID: Location] = [:]
  private var closing: Set<UUID> = []
  private var closingTasks: [UUID: Task<Bool, Never>] = [:]
  private var isClosingAll = false
  private var closingAllTask: Task<Bool, Never>?
  private var loadingTasks: [UUID: Task<WorkspaceLoadResult?, Never>] = [:]
  private let configurationLoader: (@Sendable (UUID) async throws -> WorkspaceLoadResult)?
  private let directoryLoader: (@Sendable () async throws -> [WorkspaceRepositoryEntry])?
  private var loadErrors: [UUID: WorkspaceRepositoryError] = [:]
  private var recoveryNotices: Set<UUID> = []
  private var loadErrorMessagesByID: [UUID: String] = [:]
  private var configurationDiagnostics: [UUID: [WorkspaceConfigurationDiagnostic]] = [:]
  private var copyingWorkspaceIDs: Set<UUID> = []
  private var copyWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  private var saveControllers: [UUID: WorkspaceSaveController] = [:]
  private var directoryDiagnostics: [UUID: WorkspaceRepositoryError] = [:]
  private var controllerObservations: [UUID: AnyCancellable] = [:]
  private var restorationTask: Task<Void, Never>?
  private var didScanDirectory = false
  private var didRestoreLastActive = false
  private var globalDiagnostics: [WorkspaceRepositoryError] = []
  private var restorationErrorDescription: String?
  let providerSettings: ProviderSettings
  let repository: WorkspaceRepository?
  let saveWriter: WorkspaceSaveController.Writer?
  var entries: [WorkspaceDirectoryEntry] {
    directory.values.filter { !$0.archived }.sorted {
      $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name
    }
  }
  var archivedEntries: [WorkspaceDirectoryEntry] {
    directory.values.filter { $0.archived }.sorted {
      $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name
    }
  }
  var lastActiveWorkspaceID: UUID? {
    directory.values.filter { !$0.archived && !$0.isTemporary }
      .max { ($0.lastActivatedAt ?? .distantPast) < ($1.lastActivatedAt ?? .distantPast) }?.id
  }
  var liveSessions: [WorkspaceSession] { sessionsByID.values.compactMap(\.value) }
  var diagnostics: [WorkspaceRepositoryError] {
    globalDiagnostics + directoryDiagnostics.values
  }
  var diagnosticEntries: [WorkspaceDiagnostic] {
    let directory = directoryDiagnostics.map { id, error in
      WorkspaceDiagnostic(workspaceID: id, error: error,
                          fileURL: repository?.configurationURL(for: id))
    }
    let global = globalDiagnostics.map {
      WorkspaceDiagnostic(workspaceID: nil, error: $0, fileURL: nil)
    }
    return (directory + global).sorted { $0.id < $1.id }
  }
  var loadingWorkspaceIDs: Set<UUID> { Set(loadingTasks.keys) }
  var loadDiagnostics: [UUID: WorkspaceRepositoryError] { loadErrors }
  var loadErrorMessages: [UUID: String] { loadErrorMessagesByID }
  var configurationLoadDiagnostics: [UUID: [WorkspaceConfigurationDiagnostic]] {
    configurationDiagnostics
  }
  var recoveryWorkspaceIDs: Set<UUID> { recoveryNotices }
  var restorationError: String? { restorationErrorDescription }
  var sessions: [UUID: WorkspaceSession] {
    Dictionary(uniqueKeysWithValues: liveSessions.map { ($0.id, $0) })
  }
  init(providerSettings: ProviderSettings? = nil, repository: WorkspaceRepository? = nil,
       configurationLoader: (@Sendable (UUID) async throws -> WorkspaceLoadResult)? = nil,
       directoryLoader: (@Sendable () async throws -> [WorkspaceRepositoryEntry])? = nil,
       saveWriter: WorkspaceSaveController.Writer? = nil) {
    self.providerSettings = providerSettings ?? ProviderSettings()
    self.repository = repository
    self.saveWriter = saveWriter
    if let configurationLoader {
      self.configurationLoader = configurationLoader
    } else if let repository {
      let loader: @Sendable (UUID) async throws -> WorkspaceLoadResult = { id in
        try await repository.load(id: id)
      }
      self.configurationLoader = loader
    } else {
      self.configurationLoader = nil
    }
    if let directoryLoader {
      self.directoryLoader = directoryLoader
    } else if let repository {
      let loader: @Sendable () async throws -> [WorkspaceRepositoryEntry] = {
        try await repository.list()
      }
      self.directoryLoader = loader
    } else {
      self.directoryLoader = nil
    }
    self.providerSettings.onConfigurationChanged = { [weak self] value in
      self?.updateProviderConfiguration(value)
    }
    _ = self.providerSettings.loadPersisted()
  }
  func create(name: String = "临时空间", isTemporary: Bool = true, launchTerminalProcesses: Bool = true)
    -> WorkspaceSession
  {
    let s = WorkspaceSession(
      name: name, isTemporary: isTemporary, launchTerminalProcesses: launchTerminalProcesses,
      providerSettings: providerSettings)
    _ = add(s)
    if !isTemporary {
      saveControllers[s.id]?.markConfigurationChanged()
    }
    return s
  }
  @discardableResult func add(_ s: WorkspaceSession) -> Bool {
    guard !isClosingAll, directory[s.id] == nil, !s.isClosed else { return false }
    objectWillChange.send()
    directory[s.id] = WorkspaceDirectoryEntry(
      id: s.id, name: s.name, isTemporary: s.isTemporary,
      lastActivatedAt: s.lastActivatedAt)
    sessionsByID[s.id] = WeakSession(s)
    if let repository {
      saveControllers[s.id] = WorkspaceSaveController(
        session: s, repository: repository,
        initialSavedConfiguration: nil, writer: saveWriter)
      observeSaveController(s.id)
    }
    return true
  }
  func rename(_ id: UUID, name: String) -> Bool {
    guard let old = directory[id], !closing.contains(id),
          sessionsByID[id]?.value != nil else { return false }
    objectWillChange.send()
    directory[id] = WorkspaceDirectoryEntry(
      id: id, name: name, isTemporary: old.isTemporary, archived: old.archived,
      lastActivatedAt: old.lastActivatedAt)
    if let session = sessionsByID[id]?.value {
      let wasTemporary = session.isTemporary
      session.name = name
      if wasTemporary {
        session.markPersisted()
        directory[id] = WorkspaceDirectoryEntry(
          id: id, name: session.name, isTemporary: false,
          archived: old.archived, lastActivatedAt: session.lastActivatedAt)
      }
      saveControllers[id]?.markConfigurationChanged()
    }
    return true
  }
  func session(for id: UUID) -> WorkspaceSession? {
    guard !closing.contains(id), let session = sessionsByID[id]?.value, !session.isClosed else {
      return nil
    }
    return session
  }
  func saveController(for id: UUID) -> WorkspaceSaveController? { saveControllers[id] }
  func recordActivation(_ id: UUID) {
    guard let entry = directory[id], let session = sessionsByID[id]?.value,
          !session.isClosed else { return }
    let date = Date()
    session.lastActivatedAt = date
    directory[id] = WorkspaceDirectoryEntry(
      id: id, name: entry.name, isTemporary: entry.isTemporary,
      archived: entry.archived, lastActivatedAt: date)
    objectWillChange.send()
  }
  func location(for id: UUID) -> Location? { locations[id] }
  func coordinator(for id: UUID) -> WindowCoordinator? { locations[id]?.coordinator }
  func bindWindow(_ window: NSWindow?, to coordinator: WindowCoordinator) {
    for (id, l) in locations where l.coordinator === coordinator {
      l.window = window
      locations[id] = l
    }
  }
  @discardableResult func attach(
    _ s: WorkspaceSession, to c: WindowCoordinator, window: NSWindow? = nil
  ) -> Bool {
    guard !isClosingAll, !closing.contains(s.id), !s.isClosed else { return false }
    if let existing = sessionsByID[s.id]?.value, existing !== s { return false }
    if directory[s.id] == nil { guard add(s) else { return false } }
    if let owner = locations[s.id]?.coordinator, owner !== c { return false }
    locations[s.id] = Location(window: window, coordinator: c)
    return true
  }
  func detach(_ id: UUID, from c: WindowCoordinator) {
    guard locations[id]?.coordinator === c else { return }
    locations.removeValue(forKey: id)
  }
  func beginClosing(_ id: UUID) -> Bool {
    guard !closing.contains(id), directory[id] != nil else { return false }
    closing.insert(id)
    return true
  }
  func remove(_ id: UUID) {
    objectWillChange.send()
    closing.remove(id)
    locations.removeValue(forKey: id)
    sessionsByID.removeValue(forKey: id)
    saveControllers.removeValue(forKey: id)
    controllerObservations.removeValue(forKey: id)
    directory.removeValue(forKey: id)
  }
  func releaseSession(_ id: UUID, preservingDirectory: Bool = true) {
    objectWillChange.send()
    closing.remove(id)
    locations.removeValue(forKey: id)
    sessionsByID.removeValue(forKey: id)
    let savedConfiguration = saveControllers[id]?.savedConfiguration
    let hasSavedConfiguration = savedConfiguration != nil
    saveControllers.removeValue(forKey: id)
    controllerObservations.removeValue(forKey: id)
    if let savedConfiguration, directory[id] != nil {
      directory[id] = WorkspaceDirectoryEntry(
        id: id, name: savedConfiguration.name, isTemporary: false,
        archived: savedConfiguration.archived,
        lastActivatedAt: savedConfiguration.lastActivatedAt)
    }
    if !preservingDirectory || directory[id]?.isTemporary == true || !hasSavedConfiguration {
      directory.removeValue(forKey: id)
    }
  }

  func startRestoration() async {
    if let task = restorationTask { await task.value; return }
    guard !didScanDirectory else { return }
    guard directoryLoader != nil else { return }
    let task = Task<Void, Never> { @MainActor [weak self] in
      defer { self?.restorationTask = nil }
      guard let self else { return }
      let records: [WorkspaceRepositoryEntry]
      do {
        guard let directoryLoader = self.directoryLoader else { return }
        records = try await directoryLoader()
      } catch let error as WorkspaceRepositoryError {
        self.globalDiagnostics.append(error)
        self.objectWillChange.send()
        self.didScanDirectory = true
        return
      } catch {
        self.restorationErrorDescription = String(describing: error)
        self.objectWillChange.send()
        self.didScanDirectory = true
        return
      }
      for record in records {
        switch record {
        case .entry(let entry):
          guard self.sessionsByID[entry.workspaceID]?.value == nil else { continue }
          self.directory[entry.workspaceID] = WorkspaceDirectoryEntry(
            id: entry.workspaceID, name: entry.name, isTemporary: false,
            archived: entry.archived, lastActivatedAt: entry.lastActivatedAt)
        case .diagnostic(let id, let error):
          if let id { self.directoryDiagnostics[id] = error }
        }
      }
      self.objectWillChange.send()
      self.didScanDirectory = true
    }
    restorationTask = task
    await task.value
  }

  func rescanDirectory() async {
    if let task = restorationTask {
      await task.value
      return
    }
    didScanDirectory = false
    directoryDiagnostics.removeAll()
    globalDiagnostics.removeAll()
    restorationErrorDescription = nil
    await startRestoration()
  }

  func openSaved(_ id: UUID, in coordinator: WindowCoordinator,
                 launchTerminalProcesses: Bool = true) async -> WorkspaceOpenResult {
    let loadToken = coordinator.issueWorkspaceLoadToken()
    let initialActiveID = coordinator.activeWorkspaceID
    let initialActiveProjection = coordinator.activeSession.map {
      configurationProjection($0.exportConfiguration(revision: 0))
    }
    let initialQuestions = coordinator.activeSession?.agentController.questions
    while copyingWorkspaceIDs.contains(id) {
      await withCheckedContinuation { continuation in
        copyWaiters[id, default: []].append(continuation)
      }
    }
    guard coordinator.acceptsWorkspaceLoadToken(loadToken) else { return .unavailable }
    guard coordinator.activeWorkspaceID == initialActiveID,
          coordinator.activeSession.map({ configurationProjection($0.exportConfiguration(revision: 0)) })
            == initialActiveProjection,
          coordinator.activeSession?.agentController.questions == initialQuestions else {
      return .unavailable
    }
    guard let entry = directory[id], !entry.archived, !entry.isTemporary else {
      return .unavailable
    }
    if let existing = session(for: id) {
      guard coordinator.canAcceptWorkspace else { return .unavailable }
      _ = existing
      return coordinator.open(id)
    }
    guard coordinator.canAcceptWorkspace, configurationLoader != nil else { return .unavailable }
    let loadResult: WorkspaceLoadResult?
    if let task = loadingTasks[id] {
      loadResult = await task.value
    } else {
      let task = Task<WorkspaceLoadResult?, Never> { @MainActor [weak self] in
        guard let self, let loader = self.configurationLoader else { return nil }
        do {
          return try await loader(id)
        } catch let error as WorkspaceRepositoryError {
          self.loadErrors[id] = error
          self.objectWillChange.send()
          return nil
        } catch {
          self.loadErrorMessagesByID[id] = String(describing: error)
          self.objectWillChange.send()
          return nil
        }
      }
      loadingTasks[id] = task
      objectWillChange.send()
      loadResult = await task.value
      loadingTasks[id] = nil
      objectWillChange.send()
    }
    let currentActiveProjection = coordinator.activeSession.map {
      configurationProjection($0.exportConfiguration(revision: 0))
    }
    guard coordinator.canAcceptWorkspace,
          coordinator.acceptsWorkspaceLoadToken(loadToken),
          coordinator.activeWorkspaceID == initialActiveID,
          currentActiveProjection == initialActiveProjection,
          coordinator.activeSession?.agentController.questions == initialQuestions,
          let loadResult,
          let configuration = loadResult.configuration else { return .unavailable }
    loadErrors.removeValue(forKey: id)
    loadErrorMessagesByID.removeValue(forKey: id)
    configurationDiagnostics[id] = loadResult.diagnostics
    objectWillChange.send()
    if case .recoveredFromBackup = loadResult {
      recoveryNotices.insert(id)
      objectWillChange.send()
    }
    if let owner = locations[id]?.coordinator, owner !== coordinator {
      if let window = owner.window ?? locations[id]?.window {
        coordinator.onActivateWindow?(window)
      }
      _ = owner.select(id)
      return .locatedExistingWindow(workspaceID: id)
    }
    let loadedSession = WorkspaceSession(configuration: configuration,
                                   launchTerminalProcesses: launchTerminalProcesses,
                                   providerSettings: providerSettings)
    guard registerLoaded(loadedSession, initialConfiguration: configuration) else {
      if let existing = self.session(for: id) {
        _ = existing
        return coordinator.open(id)
      }
      return .unavailable
    }
    guard coordinator.open(id) != .unavailable else {
      releaseSession(id, preservingDirectory: true)
      return .unavailable
    }
    return .opened(loadedSession)
  }

  private func registerLoaded(_ session: WorkspaceSession,
                              initialConfiguration: WorkspaceConfiguration) -> Bool {
    guard !isClosingAll, !closing.contains(session.id), !session.isClosed,
          sessionsByID[session.id]?.value == nil,
          locations[session.id] == nil else { return false }
    if directory[session.id] == nil {
      directory[session.id] = WorkspaceDirectoryEntry(
        id: session.id, name: initialConfiguration.name, isTemporary: false,
        archived: initialConfiguration.archived,
        lastActivatedAt: initialConfiguration.lastActivatedAt)
    }
    sessionsByID[session.id] = WeakSession(session)
    if let repository {
      saveControllers[session.id] = WorkspaceSaveController(
        session: session, repository: repository,
        initialSavedConfiguration: initialConfiguration, writer: saveWriter)
      observeSaveController(session.id)
    }
    objectWillChange.send()
    return true
  }

  private func observeSaveController(_ id: UUID) {
    guard let controller = saveControllers[id] else { return }
    controllerObservations[id] = controller.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
  }

  func restoreLastActive(in coordinator: WindowCoordinator,
                         launchTerminalProcesses: Bool = true) async -> WorkspaceOpenResult {
    guard !didRestoreLastActive else { return .unavailable }
    didRestoreLastActive = true
    let initialActiveID = coordinator.activeWorkspaceID
    let initialActiveProjection = coordinator.activeSession.map {
      configurationProjection($0.exportConfiguration(revision: 0))
    }
    let initialQuestions = coordinator.activeSession?.agentController.questions
    let pristine: Bool = {
      guard let initialSession = coordinator.activeSession else { return true }
      guard initialSession.isTemporary,
            initialSession.resourceStore.records.isEmpty,
            initialSession.agentController.questions.count <= 1 else { return false }
      let hasDraft = initialSession.agentController.questions.values.contains {
        !$0.draft.isEmpty || !$0.messages.isEmpty || !$0.snapshots.isEmpty
      }
      return !hasDraft
    }()
    await startRestoration()
    guard pristine else { return .unavailable }
    guard let id = lastActiveWorkspaceID else { return .unavailable }
    guard coordinator.activeWorkspaceID == initialActiveID,
          coordinator.activeSession.map({
            configurationProjection($0.exportConfiguration(revision: 0))
          }) == initialActiveProjection,
          coordinator.activeSession?.agentController.questions == initialQuestions else {
      return .unavailable
    }
    return await openSaved(id, in: coordinator,
                           launchTerminalProcesses: launchTerminalProcesses)
  }

  func copyResource(sourceWorkspaceID: UUID, resourceID: UUID,
                    toWorkspaceID: UUID) async throws -> UUID {
    guard sourceWorkspaceID != toWorkspaceID else { throw WorkspaceCopyError.targetUnavailable }
    guard !closing.contains(sourceWorkspaceID), !closing.contains(toWorkspaceID),
          !isClosingAll,
          locations[sourceWorkspaceID]?.coordinator?.canAcceptWorkspace ?? true,
          locations[toWorkspaceID]?.coordinator?.canAcceptWorkspace ?? true,
          loadingTasks[toWorkspaceID] == nil,
          copyingWorkspaceIDs.insert(toWorkspaceID).inserted else {
      throw WorkspaceCopyError.targetUnavailable
    }
    defer {
      copyingWorkspaceIDs.remove(toWorkspaceID)
      copyWaiters.removeValue(forKey: toWorkspaceID)?.forEach { $0.resume() }
    }
    let sourceSessionIdentity = session(for: sourceWorkspaceID)
    let source: WorkspaceResourceConfiguration
    if let session = session(for: sourceWorkspaceID) {
      guard !session.archived,
            let item = session.exportConfiguration().resources.first(where: { $0.id == resourceID })
      else { throw WorkspaceCopyError.resourceUnavailable }
      source = item
    } else {
      let loaded = try await loadConfigurationThrowing(sourceWorkspaceID)
      guard let configuration = loaded.configuration,
            !configuration.archived,
            let item = configuration.resources.first(where: { $0.id == resourceID })
      else { throw WorkspaceCopyError.sourceUnavailable }
      source = item
    }
    let newID = UUID()
    guard !isClosingAll, !closing.contains(sourceWorkspaceID),
          locations[sourceWorkspaceID]?.coordinator?.canAcceptWorkspace ?? true,
          ((sourceSessionIdentity == nil && session(for: sourceWorkspaceID) == nil)
           || (sourceSessionIdentity != nil && sourceSessionIdentity === session(for: sourceWorkspaceID))) else {
      throw WorkspaceCopyError.sourceUnavailable
    }
    let copied = WorkspaceResourceConfiguration(
      id: newID, destination: source.destination,
      customTitle: source.customTitle, order: source.order)
    if let target = session(for: toWorkspaceID) {
      return try appendCopiedDescriptor(target, copied: copied, newID: newID)
    }
    guard let repository else { throw WorkspaceCopyError.targetUnavailable }
    let targetResult = try await loadConfigurationThrowing(toWorkspaceID)
    guard !closing.contains(sourceWorkspaceID),
          locations[sourceWorkspaceID]?.coordinator?.canAcceptWorkspace ?? true else {
      throw WorkspaceCopyError.sourceUnavailable
    }
    if let sourceSessionIdentity {
      guard let current = session(for: sourceWorkspaceID), current === sourceSessionIdentity,
            !current.isClosed, !current.archived,
            current.resourceStore.records[resourceID] != nil else {
        throw WorkspaceCopyError.sourceUnavailable
      }
    } else {
      guard let sourceEntry = directory[sourceWorkspaceID], !sourceEntry.archived,
            !sourceEntry.isTemporary else { throw WorkspaceCopyError.sourceUnavailable }
    }
    guard let target = targetResult.configuration,
          !target.archived, session(for: toWorkspaceID) == nil,
          !closing.contains(toWorkspaceID), !isClosingAll,
          locations[toWorkspaceID]?.coordinator?.canAcceptWorkspace ?? true else {
      if let loadedTarget = session(for: toWorkspaceID), !loadedTarget.archived,
         !isClosingAll, !closing.contains(toWorkspaceID),
         locations[toWorkspaceID]?.coordinator?.canAcceptWorkspace ?? true,
         loadingTasks[toWorkspaceID] == nil {
        return try appendCopiedDescriptor(loadedTarget, copied: copied, newID: newID)
      }
      throw WorkspaceCopyError.targetUnavailable
    }
    var updated = target
    updated.resources.append(
      WorkspaceResourceConfiguration(
        id: copied.id, destination: copied.destination,
        customTitle: copied.customTitle,
        order: (updated.resources.map(\.order).max() ?? -1) + 1))
    do {
      _ = try await repository.save(updated, expectedRevision: target.revision)
    } catch let error as WorkspaceRepositoryError {
      if case .revisionConflict = error { throw WorkspaceCopyError.conflict }
      throw WorkspaceCopyError.saveFailed(error.localizedDescription)
    } catch {
      throw WorkspaceCopyError.saveFailed(error.localizedDescription)
    }
    return newID
  }

  private func loadConfigurationThrowing(_ id: UUID) async throws -> WorkspaceLoadResult {
    guard let configurationLoader else { throw WorkspaceCopyError.sourceUnavailable }
    return try await configurationLoader(id)
  }

  private func appendCopiedDescriptor(
    _ target: WorkspaceSession, copied: WorkspaceResourceConfiguration, newID: UUID
  ) throws -> UUID {
    guard !target.archived else { throw WorkspaceCopyError.archivedWorkspace }
    guard !target.isClosed, !isClosingAll,
          !closing.contains(target.id), loadingTasks[target.id] == nil,
          locations[target.id]?.coordinator?.canAcceptWorkspace ?? true,
          target.resourceStore.records[newID] == nil else {
      throw WorkspaceCopyError.targetUnavailable
    }
    let record: ResourceRecord
    switch copied.destination {
    case .blank:
      record = ResourceRecord(id: newID, kind: .web, groupID: target.id,
                              title: "空白网页", location: .web(nil),
                              readCapabilities: [.address, .title, .text],
                              customTitle: copied.customTitle)
    case .web(let url):
      record = ResourceRecord(id: newID, kind: .web, groupID: target.id,
                              title: URL(string: url)?.host ?? "空白网页",
                              location: .web(URL(string: url)),
                              readCapabilities: [.address, .title, .text], customTitle: copied.customTitle)
    case .terminal(let directory):
      record = ResourceRecord(id: newID, kind: .localTerminal, groupID: target.id,
                              title: "终端", location: .localTerminal(directory: directory),
                              readCapabilities: [.output], customTitle: copied.customTitle)
    case .ssh(let host, let user, let port):
      record = ResourceRecord(id: newID, kind: .sshTerminal, groupID: target.id,
                              title: user.isEmpty ? host : user + "@" + host,
                              location: .ssh(host: host, user: user, port: port),
                              readCapabilities: [.output], customTitle: copied.customTitle)
    }
    _ = target.resourceStore.restoreDescriptor(record)
    saveControllers[target.id]?.markConfigurationChanged()
    return newID
  }

  func configurationSnapshot(for id: UUID) async -> WorkspaceConfiguration? {
    if let session = session(for: id) {
      return session.exportConfiguration(
        revision: saveControllers[id]?.savedConfiguration?.revision ?? 0)
    }
    guard let repository, let result = try? await repository.load(id: id),
          let configuration = result.configuration else { return nil }
    return configuration
  }

  func configurationsForSearch() async -> [WorkspaceConfiguration] {
    var values: [WorkspaceConfiguration] = []
    for entry in directory where !entry.value.archived {
      if let configuration = await configurationSnapshot(for: entry.key) {
        values.append(configuration)
      }
    }
    return values
  }

  func archive(_ id: UUID) async -> Bool {
    guard !copyingWorkspaceIDs.contains(id) else { return false }
    if let task = closingTasks[id] { return await task.value }
    guard !isClosingAll, !closing.contains(id) else { return false }
    if let liveSession = session(for: id),
       let controller = saveControllers[id] {
      guard !liveSession.isTemporary,
            locations[id]?.coordinator?.canAcceptWorkspace ?? true else { return false }
      let oldArchived = liveSession.archived
      let owner = locations[id]?.coordinator
      owner?.beginClosePreparation()
      let task = Task<Bool, Never> { @MainActor [weak self] in
        guard let self else { return false }
        liveSession.archived = true
        guard let decisions = await self.prepareSessionsClose([liveSession]),
              decisions.isEmpty,
              let saved = controller.savedConfiguration else {
          liveSession.archived = oldArchived
          owner?.cancelClosePreparation()
          return false
        }
        self.directory[id] = WorkspaceDirectoryEntry(
          id: id, name: saved.name, isTemporary: false, archived: true,
          lastActivatedAt: saved.lastActivatedAt)
        self.objectWillChange.send()
        if let owner {
          return await owner.cleanupPreparedWorkspace(id)
        }
        guard self.beginClosing(id) else { return false }
        await liveSession.close()
        self.releaseSession(id, preservingDirectory: true)
        return true
      }
      closingTasks[id] = task
      let result = await task.value
      closingTasks[id] = nil
      return result
    }
    guard let repository,
          let configuration = await configurationSnapshot(for: id) else { return false }
    guard session(for: id) == nil, !closing.contains(id) else { return false }
    var updated = configuration
    updated.archived = true
    let result: WorkspaceSaveResult
    do {
      result = try await repository.save(updated, expectedRevision: configuration.revision)
    } catch {
      loadErrorMessagesByID[id] = String(describing: error)
      objectWillChange.send()
      return false
    }
    guard case let .saved(envelope) = result else {
      return false
    }
    directory[id] = WorkspaceDirectoryEntry(id: id, name: envelope.configuration.name,
                                             isTemporary: false, archived: true,
                                             lastActivatedAt: envelope.configuration.lastActivatedAt)
    objectWillChange.send()
    return true
  }

  func unarchive(_ id: UUID) async -> Bool {
    guard !copyingWorkspaceIDs.contains(id) else { return false }
    guard !isClosingAll, !closing.contains(id), session(for: id) == nil else { return false }
    guard let repository,
          let configuration = await configurationSnapshot(for: id) else { return false }
    guard session(for: id) == nil, !closing.contains(id) else { return false }
    var updated = configuration
    updated.archived = false
    let result: WorkspaceSaveResult
    do {
      result = try await repository.save(updated, expectedRevision: configuration.revision)
    } catch {
      loadErrorMessagesByID[id] = String(describing: error)
      objectWillChange.send()
      return false
    }
    guard case let .saved(envelope) = result else { return false }
    directory[id] = WorkspaceDirectoryEntry(id: id, name: envelope.configuration.name,
                                             isTemporary: false, archived: false,
                                             lastActivatedAt: envelope.configuration.lastActivatedAt)
    objectWillChange.send()
    return true
  }
  func updateProviderConfiguration(_ c: ProviderConfiguration?) {
    for s in liveSessions { s.agentController.updateConfiguration(c) }
  }
  @discardableResult
  func prepareSessionClose(_ session: WorkspaceSession,
                           resolver: WorkspaceCloseResolver? = nil) async
    -> (accepted: Bool, discard: Bool)
  {
    guard let controller = saveControllers[session.id] else {
      return (true, false)
    }
    while true {
      if await controller.saveNow() { return (true, false) }
      let choice = await resolver?(session, controller.lastErrorMessage)
        ?? .cancel
      switch choice {
      case .retry:
        continue
      case .cancel:
        return (false, false)
      case .discard:
        return (true, true)
      }
    }
  }

  @discardableResult
  func prepareSessionsClose(
    _ sessions: [WorkspaceSession], resolver: WorkspaceCloseResolver? = nil
  ) async -> Set<UUID>? {
    let ordered = sessions.sorted { $0.id.uuidString < $1.id.uuidString }
    var discardIDs: Set<UUID> = []
    while true {
      for session in ordered where !discardIDs.contains(session.id) {
        let preparation = await prepareSessionClose(session, resolver: resolver)
        guard preparation.accepted else { return nil }
        if preparation.discard { discardIDs.insert(session.id) }
      }
      var changed = false
      for session in ordered where !discardIDs.contains(session.id) {
        if saveControllers[session.id]?.hasUnsavedConfiguration == true {
          changed = true
          break
        }
      }
      if !changed { break }
    }
    for session in ordered {
      saveControllers[session.id]?.stopObserving()
    }
    return discardIDs
  }

  @discardableResult
  func close(_ id: UUID, resolver: WorkspaceCloseResolver? = nil) async -> Bool {
    if let task = closingTasks[id] {
      return await task.value
    }
    if let owner = locations[id]?.coordinator {
      return await owner.closeWorkspace(id, resolver: resolver)
    }
    let task = Task<Bool, Never> { @MainActor [weak self] in
      guard let self, !self.isClosingAll,
            let session = self.sessionsByID[id]?.value else { return false }
      let preparation = await self.prepareSessionClose(session, resolver: resolver)
      guard preparation.accepted, self.beginClosing(id) else { return false }
      if preparation.discard { _ = await self.saveControllers[id]?.discardPendingChanges() }
      self.saveControllers[id]?.stopObserving()
      await session.close()
      self.releaseSession(id, preservingDirectory: true)
      return true
    }
    closingTasks[id] = task
    let result = await task.value
    closingTasks[id] = nil
    return result
  }

  @discardableResult
  func closeAll(resolver: WorkspaceCloseResolver? = nil) async -> Bool {
    if let task = closingAllTask {
      return await task.value
    }
    guard !isClosingAll else { return false }
    guard locations.values.compactMap(\.coordinator).allSatisfy({
      !$0.isClosing && $0.closingTask == nil
    }), closingTasks.isEmpty else { return false }
    isClosingAll = true
    let task = Task<Bool, Never> { @MainActor [weak self] in
      guard let self else { return false }
      var coordinators: [WindowCoordinator] = []
      for location in self.locations.values {
        if let coordinator = location.coordinator,
          !coordinators.contains(where: { $0 === coordinator })
        {
          coordinators.append(coordinator)
        }
      }
      for coordinator in coordinators {
        coordinator.beginClosePreparation()
      }
      let allSessions = self.liveSessions
      guard let discardedIDs = await self.prepareSessionsClose(allSessions, resolver: resolver) else {
        for coordinator in coordinators { coordinator.cancelClosePreparation() }
        self.isClosingAll = false
        return false
      }
      let unownedIDs = self.sessionsByID.compactMap { id, weakSession in
        self.locations[id] == nil && weakSession.value != nil ? id : nil
      }
      for coordinator in coordinators {
        let discardIDs = discardedIDs.intersection(Set(coordinator.loadedSessions.keys))
        guard await coordinator.cleanupPreparedWorkspaces(discardIDs: discardIDs) else {
          self.isClosingAll = false
          return false
        }
      }
      for id in unownedIDs {
        if let session = self.sessionsByID[id]?.value {
          if discardedIDs.contains(id) {
            _ = await self.saveControllers[id]?.discardPendingChanges()
          }
          await session.close()
        }
        self.releaseSession(id, preservingDirectory: true)
      }
      for id in self.directory.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
        if self.directory[id]?.isTemporary == true {
          self.remove(id)
        }
      }
      return true
    }
    closingAllTask = task
    let result = await task.value
    closingAllTask = nil
    return result
  }
}
