import Combine
import Foundation
import os

enum AgentRunState: Equatable, Sendable {
  case requesting
  case completed(String)
  case failed(String)
  case cancelled
}
struct AgentRun: Identifiable, Equatable, Sendable {
  let id: UUID
  let questionID: UUID
  let request: AgentRequest
  var state: AgentRunState
}
struct AgentQuestion: Identifiable, Equatable, Sendable {
  let id: UUID
  var draft: String
  var selectedResourceIDs: [UUID]
  var snapshots: [ResourceSnapshot]
  var previewConfirmed: Bool
  var messages: [AgentMessage]
  var runHistory: [UUID: AgentRun]
  var latestRunID: UUID?
}
struct ActiveAgentRequest: Identifiable, Equatable, Sendable {
  let questionID: UUID
  let runID: UUID
  let request: AgentRequest
  var id: UUID { runID }
}

@MainActor final class AgentController: ObservableObject {
  let store: ResourceStore
  let service: ConfiguredAgentService
  @Published private(set) var configuration: ProviderConfiguration?
  @Published private(set) var questions: [UUID: AgentQuestion] = [:]
  @Published private(set) var questionOrder: [UUID] = []
  @Published private(set) var currentQuestionID: UUID
  @Published private(set) var activeRequest: ActiveAgentRequest?
  @Published private(set) var isCancellingRequest = false
  private var currentQuestion: AgentQuestion { questions[currentQuestionID]! }
  var question: String {
    get { currentQuestion.draft }
    set {
      guard !isShutdown else { return }
      questions[currentQuestionID]!.draft = newValue
    }
  }
  var selectedResourceIDs: [UUID] { currentQuestion.selectedResourceIDs }
  var previewSnapshots: [ResourceSnapshot] { currentQuestion.snapshots }
  var run: AgentRun? {
    currentQuestion.latestRunID.flatMap { currentQuestion.runHistory[$0] }
  }
  var messages: [AgentMessage] { currentQuestion.messages }
  var runHistory: [UUID: AgentRun] { currentQuestion.runHistory }
  var isReading: Bool { reads[currentQuestionID]?.task != nil }
  var previewError: String? { previewSnapshots.first(where: { $0.errorMessage != nil })?.errorMessage }
  var isRequesting: Bool { activeRequest != nil || isCancellingRequest }
  private let reader: @Sendable (UUID, Int) async -> ResourceSnapshot
  private var runTask: Task<Void, Never>?
  private struct QuestionRead {
    let generation: Int
    var task: Task<Void, Never>?
  }
  @Published private var reads: [UUID: QuestionRead] = [:]
  private var requestGeneration = 0
  private var pendingRequestCleanupID: UUID?
  private var retiredTasks: [Task<Void, Never>] = []
  private var isShutdown = false
  private var shutdownTask: Task<Void, Never>?

  init(
    store: ResourceStore, service: ConfiguredAgentService? = nil, configuration: ProviderConfiguration? = nil,
    reader: (@Sendable (UUID, Int) async -> ResourceSnapshot)? = nil
  ) {
    self.store = store
    self.service = service ?? ConfiguredAgentService()
    self.configuration = configuration
    self.reader = reader ?? { id, limit in await store.read(resourceID: id, maxCharacters: limit) }
    let id = UUID()
    currentQuestionID = id
    questions[id] = AgentQuestion(
      id: id, draft: "", selectedResourceIDs: [], snapshots: [], previewConfirmed: false, messages: [], runHistory: [:])
    questionOrder = [id]
  }
  func updateConfiguration(_ value: ProviderConfiguration?) { configuration = value }
  var canSend: Bool {
    guard !isShutdown, activeRequest == nil, pendingRequestCleanupID == nil,
      !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !selectedResourceIDs.isEmpty, previewSnapshots.count == selectedResourceIDs.count,
      previewSnapshots.map(\.resourceID) == selectedResourceIDs,
      !previewSnapshots.contains(where: { $0.errorMessage != nil }), configuration != nil
    else { return false }
    return currentQuestion.previewConfirmed
  }
  @discardableResult func newQuestion() -> UUID? {
    guard !isShutdown else { return nil }
    let id = UUID()
    questions[id] = AgentQuestion(
      id: id, draft: "", selectedResourceIDs: [], snapshots: [], previewConfirmed: false, messages: [], runHistory: [:])
    questionOrder.append(id)
    selectQuestion(id)
    return id
  }
  func selectQuestion(_ id: UUID) {
    guard !isShutdown, id != currentQuestionID, questions[id] != nil else { return }
    currentQuestionID = id
  }
  func run(for id: UUID) -> AgentRun? { questions.values.compactMap { $0.runHistory[id] }.first }
  func addResource(_ id: UUID) {
    guard !isShutdown, store.records[id] != nil, !selectedResourceIDs.contains(id) else { return }
    questions[currentQuestionID]!.selectedResourceIDs.append(id)
    invalidate()
  }
  func removeResource(_ id: UUID) {
    questions[currentQuestionID]!.selectedResourceIDs.removeAll { $0 == id }
    invalidate()
  }

  func readPreview() {
    guard !isShutdown else { return }
    let questionID = currentQuestionID
    if let old = reads[questionID]?.task {
      retiredTasks.append(old)
      old.cancel()
    }
    let ids = selectedResourceIDs
    let token = (reads[questionID]?.generation ?? 0) + 1
    setSnapshots([], confirmed: false)
    let task = Task { [weak self] in
      guard let self else { return }
      var snapshots: [ResourceSnapshot] = []
      var total = 0
      for id in ids {
        guard !Task.isCancelled else { return }
        let remaining = 48_000 - total
        if remaining <= 0 {
          snapshots.append(.failure(resourceID: id, message: "预览资料已超过预算。"))
          continue
        }
        let snapshot = await reader(id, min(12_000, remaining))
        if let text = snapshot.text {
          let amount = min(text.count, min(12_000, remaining))
          let clipped = amount == text.count ? text : String(text.suffix(amount))
          let start = snapshot.range.map { max($0.lowerBound, $0.upperBound - amount) }
          snapshots.append(
            ResourceSnapshot(
              resourceID: snapshot.resourceID, collectedAt: snapshot.collectedAt, text: clipped,
              isTruncated: snapshot.isTruncated || amount < text.count, errorMessage: snapshot.errorMessage,
              sourceURL: snapshot.sourceURL, title: snapshot.title, range: start.map { $0..<$0 + amount },
              knownDirectory: snapshot.knownDirectory, lifecycle: snapshot.lifecycle,
              runtimeErrorMessage: snapshot.runtimeErrorMessage, instanceID: snapshot.instanceID))
          total += amount
        } else {
          snapshots.append(snapshot)
        }
      }
      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        guard let self, !self.isShutdown, self.reads[questionID]?.generation == token else { return }
        self.questions[questionID]!.snapshots = snapshots
        self.questions[questionID]!.previewConfirmed = false
        self.reads[questionID]!.task = nil
      }
    }
    reads[questionID] = QuestionRead(generation: token, task: task)
  }
  @discardableResult func confirmPreview() -> Bool {
    guard !isShutdown, !isReading, !selectedResourceIDs.isEmpty, previewSnapshots.count == selectedResourceIDs.count,
      previewSnapshots.map(\.resourceID) == selectedResourceIDs,
      !previewSnapshots.contains(where: { $0.errorMessage != nil })
    else { return false }
    setSnapshots(previewSnapshots, confirmed: true)
    return true
  }
  func send() {
    guard canSend, let config = configuration else { return }
    let q = currentQuestion
    let request = AgentRequest(question: q.draft, snapshots: q.snapshots, configuration: config)
    let created = AgentRun(id: UUID(), questionID: q.id, request: request, state: .requesting)
    questions[q.id]!.latestRunID = created.id
    questions[q.id]!.runHistory[created.id] = created
    questions[q.id]!.messages.append(AgentMessage(runID: created.id, role: .user, text: request.question))
    question = ""
    startRequest(created)
  }
  func retry(questionID: UUID? = nil) {
    guard !isShutdown, activeRequest == nil, pendingRequestCleanupID == nil else { return }
    let id = questionID ?? currentQuestionID
    guard let q = questions[id], let runID = q.latestRunID, let prior = q.runHistory[runID], prior.state.retryable
    else {
      return
    }
    let retried = AgentRun(id: UUID(), questionID: id, request: prior.request, state: .requesting)
    questions[id]!.runHistory[retried.id] = retried
    questions[id]!.latestRunID = retried.id
    startRequest(retried)
  }
  private func startRequest(_ created: AgentRun) {
    StudioLog.agent.info(
      "event=request_started question=\(created.questionID.uuidString, privacy: .public) run=\(created.id.uuidString, privacy: .public)"
    )
    activeRequest = ActiveAgentRequest(questionID: created.questionID, runID: created.id, request: created.request)
    requestGeneration += 1
    let token = requestGeneration
    runTask = Task { [weak self, service] in
      do {
        try Task.checkCancellation()
        let answer = try await service.answer(request: created.request)
        try Task.checkCancellation()
        await MainActor.run {
          self?.finish(created, state: .completed(answer), token: token)
          self?.releaseRequestSlot(created.id)
        }
      } catch {
        await MainActor.run {
          self?.finish(
            created,
            state: (error as? AgentServiceError) == .cancelled
              ? .cancelled : .failed((error as? LocalizedError)?.errorDescription ?? "Agent 请求失败"), token: token)
          self?.releaseRequestSlot(created.id)
        }
      }
    }
  }
  func cancel(questionID: UUID? = nil) {
    if let questionID { cancelReading(questionID: questionID) } else { cancelReading() }
    guard let active = activeRequest, questionID == nil || active.questionID == questionID else { return }
    requestGeneration += 1
    StudioLog.agent.info(
      "event=request_cancelled question=\(active.questionID.uuidString, privacy: .public) run=\(active.runID.uuidString, privacy: .public)"
    )
    pendingRequestCleanupID = active.runID
    isCancellingRequest = true
    if let task = runTask {
      retiredTasks.append(task)
      task.cancel()
    }
    if var r = questions[active.questionID]?.runHistory[active.runID] {
      r.state = .cancelled
      questions[active.questionID]!.runHistory[active.runID] = r
    }
    activeRequest = nil
    runTask = nil
  }
  func cancelReading(questionID: UUID? = nil) {
    let id = questionID ?? currentQuestionID
    guard questions[id] != nil else { return }
    let generation = (reads[id]?.generation ?? 0) + 1
    if let task = reads[id]?.task {
      retiredTasks.append(task)
      task.cancel()
    }
    reads[id] = QuestionRead(generation: generation, task: nil)
  }
  func newChat() {
    cancel()
    cancelAllReads()
    let id = currentQuestionID
    questions = [
      id: AgentQuestion(
        id: id, draft: "", selectedResourceIDs: [], snapshots: [], previewConfirmed: false, messages: [],
        runHistory: [:])
    ]
    questionOrder = [id]
  }
  func shutdown() {
    isShutdown = true
    cancel()
    cancelAllReads()
  }
  func shutdownAndWait() async {
    if let shutdownTask {
      await shutdownTask.value
      return
    }
    isShutdown = true
    cancel()
    cancelAllReads()
    let pending = retiredTasks + [runTask].compactMap { $0 }
    retiredTasks.removeAll()
    let task = Task { for t in pending { await t.value } }
    shutdownTask = task
    await task.value
  }

  private func finish(_ created: AgentRun, state: AgentRunState, token: Int) {
    guard !isShutdown, requestGeneration == token, activeRequest?.runID == created.id else { return }
    StudioLog.agentState(questionID: created.questionID, runID: created.id, state: state)
    var updated = created
    updated.state = state
    questions[created.questionID]!.runHistory[created.id] = updated
    if case .completed(let answer) = state {
      questions[created.questionID]!.messages.append(AgentMessage(runID: created.id, role: .assistant, text: answer))
    }
    questions[created.questionID]!.latestRunID = created.id
    activeRequest = nil
    runTask = nil
  }
  private func releaseRequestSlot(_ runID: UUID) {
    if pendingRequestCleanupID == runID {
      pendingRequestCleanupID = nil
      isCancellingRequest = false
    }
  }
  private func setSnapshots(_ snapshots: [ResourceSnapshot], confirmed: Bool) {
    questions[currentQuestionID]!.snapshots = snapshots
    questions[currentQuestionID]!.previewConfirmed = confirmed
  }
  private func invalidate() {
    cancelReading()
    setSnapshots([], confirmed: false)
  }
  private func cancelAllReads() {
    for read in reads.values {
      if let task = read.task {
        retiredTasks.append(task)
        task.cancel()
      }
    }
    reads.removeAll()
  }
}
extension AgentRunState {
  fileprivate var retryable: Bool {
    if case .failed = self { return true }
    if case .cancelled = self { return true }
    return false
  }
}
extension AgentController {
  convenience init(
    store: ResourceStore, service: ConfiguredResponsesService, configuration: ProviderConfiguration? = nil,
    reader: (@Sendable (UUID, Int) async -> ResourceSnapshot)? = nil
  ) {
    self.init(
      store: store, service: ConfiguredAgentService(credentials: service.credentials, responses: service.provider),
      configuration: configuration, reader: reader)
  }
}
