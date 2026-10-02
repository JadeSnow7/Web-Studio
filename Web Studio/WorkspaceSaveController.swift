import Combine
import Foundation

enum WorkspaceSaveState: Equatable, Sendable {
  case clean(revision: Int?)
  case dirty(generation: Int)
  case saving(generation: Int)
  case saved(generation: Int, revision: Int)
  case failed(generation: Int, message: String)
}

@MainActor
final class WorkspaceSaveController: ObservableObject {
  typealias Writer = @Sendable
    (WorkspaceConfiguration, Int?) async throws -> WorkspaceConfiguration
  weak var session: WorkspaceSession?
  let repository: WorkspaceRepository
  let debounce: Duration
  @Published private(set) var state: WorkspaceSaveState
  var savedConfiguration: WorkspaceConfiguration? { lastSavedConfiguration }
  var lastErrorMessage: String { lastError ?? "保存失败" }
  var hasUnsavedConfiguration: Bool {
    guard let session, !session.isTemporary else { return false }
    return Self.projection(session.exportConfiguration(revision: 0))
      != lastSavedConfiguration.map(Self.projection)
  }
  private let writer: Writer
  private var generation = 0
  private var lastSavedGeneration = 0
  private var revision: Int?
  private var observationTask: Task<Void, Never>?
  private var debounceTask: Task<Void, Never>?
  private var writeTask: Task<Void, Never>?
  private var lastSavedConfiguration: WorkspaceConfiguration?
  private var observedProjection: WorkspaceConfiguration?
  private var suspended = false
  private var lastError: String?
  private var sessionObservation: AnyCancellable?
  private var resourceObservation: AnyCancellable?

  init(session: WorkspaceSession, repository: WorkspaceRepository,
       initialSavedConfiguration: WorkspaceConfiguration? = nil,
       debounce: Duration = .milliseconds(500), writer: Writer? = nil) {
    self.session = session
    self.repository = repository
    self.debounce = debounce
    self.lastSavedConfiguration = initialSavedConfiguration
    self.revision = initialSavedConfiguration?.revision
    self.observedProjection = initialSavedConfiguration.map(Self.projection)
    self.state = .clean(revision: initialSavedConfiguration?.revision)
    self.writer = writer ?? { configuration, expectedRevision in
      let result = try await repository.save(configuration, expectedRevision: expectedRevision)
      guard case let .saved(envelope) = result else {
        throw WorkspaceRepositoryError.corrupt(configuration.workspaceID)
      }
      return envelope.configuration
    }
    sessionObservation = session.objectWillChange.sink { [weak self] _ in
      self?.scheduleObservation()
    }
    resourceObservation = session.resourceStore.objectWillChange.sink { [weak self] _ in
      self?.scheduleObservation()
    }
  }

  private static func projection(_ configuration: WorkspaceConfiguration)
    -> WorkspaceConfiguration {
    var value = configuration
    value.revision = 0
    return value
  }

  private func scheduleObservation() {
    guard !suspended else { return }
    observationTask?.cancel()
    observationTask = Task { [weak self] in
      await Task.yield()
      guard let self else { return }
      self.observationTask = nil
      self.markConfigurationChanged()
    }
  }

  func markConfigurationChanged() {
    guard !suspended, let session, !session.isTemporary, !session.isClosed else { return }
    let current = Self.projection(session.exportConfiguration(revision: 0))
    guard observedProjection != current else { return }
    observedProjection = current
    generation += 1
    state = lastError.map { .failed(generation: generation, message: $0) }
      ?? .dirty(generation: generation)
    scheduleDebounce()
  }

  private func scheduleDebounce() {
    debounceTask?.cancel()
    let expectedGeneration = generation
    debounceTask = Task { [weak self] in
      guard let self else { return }
      do { try await Task.sleep(for: self.debounce) } catch { return }
      guard !Task.isCancelled, self.generation == expectedGeneration,
            self.lastError == nil else { return }
      _ = await self.flush()
    }
  }

  func saveNow() async -> Bool {
    debounceTask?.cancel()
    return await flush()
  }

  func flush() async -> Bool {
    debounceTask?.cancel()
    guard !suspended, let session, !session.isTemporary, !session.isClosed else { return true }
    while !suspended {
      if let writeTask {
        await writeTask.value
        if case .failed = state { return false }
        continue
      }
      let projection = Self.projection(session.exportConfiguration(revision: 0))
      if observedProjection != projection {
        observedProjection = projection
        generation += 1
        state = .dirty(generation: generation)
      }
      guard generation > lastSavedGeneration || lastSavedConfiguration == nil else {
        return true
      }
      let writeGeneration = generation
      let snapshot = session.exportConfiguration(revision: revision ?? 0)
      state = .saving(generation: writeGeneration)
      let task = Task { @MainActor [weak self] in
        guard let self else { return }
        defer { self.writeTask = nil }
        do {
          let result = try await self.writer(snapshot, self.revision)
          self.revision = result.revision
          self.lastSavedConfiguration = result
          self.lastSavedGeneration = writeGeneration
          self.lastError = nil
          session.markPersisted()
          let latest = Self.projection(session.exportConfiguration(revision: 0))
          if latest == Self.projection(result) {
            self.observedProjection = latest
            self.state = .saved(generation: writeGeneration, revision: result.revision)
          } else {
            self.observedProjection = latest
            self.generation += 1
            self.state = .dirty(generation: self.generation)
          }
        } catch {
          self.lastError = String(describing: error)
          self.state = .failed(generation: writeGeneration, message: self.lastError!)
        }
      }
      writeTask = task
      await task.value
      if case .failed = state { return false }
    }
    return lastSavedConfiguration != nil
  }

  func retry() async -> Bool {
    guard case .failed = state else { return false }
    lastError = nil
    lastSavedGeneration = max(0, generation - 1)
    state = .dirty(generation: generation)
    return await flush()
  }

  func discardPendingChanges() async -> WorkspaceConfiguration? {
    suspended = true
    observationTask?.cancel()
    debounceTask?.cancel()
    if let writeTask { await writeTask.value }
    return lastSavedConfiguration
  }

  func stopObserving() {
    suspended = true
    observationTask?.cancel()
    debounceTask?.cancel()
    sessionObservation?.cancel()
    resourceObservation?.cancel()
  }

  deinit {
    observationTask?.cancel()
    debounceTask?.cancel()
    writeTask?.cancel()
    sessionObservation?.cancel()
    resourceObservation?.cancel()
  }
}
