import Combine
import Foundation

enum AgentRunState: Equatable, Sendable { case requesting, completed(String), failed(String), cancelled }
struct AgentRun: Identifiable, Equatable, Sendable { let id: UUID; let questionID: UUID; let request: AgentRequest; var state: AgentRunState }
struct AgentQuestion: Identifiable, Equatable, Sendable {
    let id: UUID; var draft: String; var selectedResourceIDs: [UUID]; var snapshots: [ResourceSnapshot]
    var previewConfirmed: Bool; var messages: [AgentMessage]; var runHistory: [UUID: AgentRun]
}
struct ActiveAgentRequest: Identifiable, Equatable, Sendable { let questionID: UUID; let runID: UUID; let request: AgentRequest; var id: UUID { runID } }

@MainActor final class AgentController: ObservableObject {
    let store: ResourceStore; let service: ConfiguredAgentService
    @Published private(set) var configuration: ProviderConfiguration?
    @Published private(set) var questions: [UUID: AgentQuestion] = [:]
    @Published private(set) var questionOrder: [UUID] = []
    @Published private(set) var currentQuestionID: UUID
    @Published private(set) var activeRequest: ActiveAgentRequest?
    @Published private(set) var isCancellingRequest = false
    @Published var question = "" { didSet { updateDraft() } }
    @Published private(set) var selectedResourceIDs: [UUID] = []
    @Published private(set) var previewSnapshots: [ResourceSnapshot] = []
    @Published private(set) var run: AgentRun?
    @Published private(set) var messages: [AgentMessage] = []
    @Published private(set) var runHistory: [UUID: AgentRun] = [:]
    @Published private(set) var isReading = false; @Published private(set) var previewError: String?
    var isRequesting: Bool { activeRequest != nil || isCancellingRequest }
    private let reader: @Sendable (UUID, Int) async -> ResourceSnapshot
    private var readTask: Task<Void, Never>?; private var runTask: Task<Void, Never>?
    private var readTasks: [UUID: Task<Void, Never>] = [:]; private var readGenerations: [UUID: Int] = [:]
    private var readingQuestions: Set<UUID> = []; private var latestRunIDs: [UUID: UUID] = [:]
    private var readGeneration = 0; private var requestGeneration = 0
    private var pendingRequestCleanupID: UUID?
    private var retiredTasks: [Task<Void, Never>] = []; private var isShutdown = false; private var shutdownTask: Task<Void, Never>?

    init(store: ResourceStore, service: ConfiguredAgentService? = nil, configuration: ProviderConfiguration? = nil,
         reader: (@Sendable (UUID, Int) async -> ResourceSnapshot)? = nil) {
        self.store = store; self.service = service ?? ConfiguredAgentService(); self.configuration = configuration; self.reader = reader ?? { id, limit in await store.read(resourceID: id, maxCharacters: limit) }
        let id = UUID(); currentQuestionID = id
        questions[id] = AgentQuestion(id: id, draft: "", selectedResourceIDs: [], snapshots: [], previewConfirmed: false, messages: [], runHistory: [:]); questionOrder = [id]
    }
    func updateConfiguration(_ value: ProviderConfiguration?) { configuration = value }
    var canSend: Bool {
        guard !isShutdown, activeRequest == nil, pendingRequestCleanupID == nil, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !selectedResourceIDs.isEmpty, previewSnapshots.count == selectedResourceIDs.count,
              previewSnapshots.map(\.resourceID) == selectedResourceIDs,
              !previewSnapshots.contains(where: { $0.errorMessage != nil }), configuration != nil else { return false }
        return questions[currentQuestionID]?.previewConfirmed == true
    }
    @discardableResult func newQuestion() -> UUID? {
        guard !isShutdown else { return nil }; persist()
        let id = UUID(); questions[id] = AgentQuestion(id: id, draft: "", selectedResourceIDs: [], snapshots: [], previewConfirmed: false, messages: [], runHistory: [:]); questionOrder.append(id); selectQuestion(id); return id
    }
    func selectQuestion(_ id: UUID) { guard !isShutdown, id != currentQuestionID, let q = questions[id] else { return }; persist(); currentQuestionID = id; load(q) }
    func run(for id: UUID) -> AgentRun? { questions.values.compactMap { $0.runHistory[id] }.first }
    func addResource(_ id: UUID) { guard !isShutdown, store.records[id] != nil, !selectedResourceIDs.contains(id) else { return }; selectedResourceIDs.append(id); invalidate(); persist() }
    func removeResource(_ id: UUID) { selectedResourceIDs.removeAll { $0 == id }; invalidate(); persist() }

    func readPreview() {
        guard !isShutdown else { return }; persist(); let questionID = currentQuestionID; if let old = readTasks[questionID] { retiredTasks.append(old); old.cancel(); readTasks[questionID] = nil }; readTask = nil; readGeneration += 1
        let ids = selectedResourceIDs; let token = (readGenerations[questionID] ?? 0) + 1
        readGenerations[questionID] = token; readingQuestions.insert(questionID)
        previewSnapshots = []; previewError = nil; isReading = true; setSnapshots([], confirmed: false)
        readTask = Task { [weak self] in
            guard let self else { return }; var snapshots: [ResourceSnapshot] = []; var total = 0
            for id in ids {
                guard !Task.isCancelled else { return }; let remaining = 48_000 - total
                if remaining <= 0 { snapshots.append(.failure(resourceID: id, message: "预览资料已超过预算。")); continue }
                let snapshot = await reader(id, min(12_000, remaining))
                if let text = snapshot.text {
                    let amount = min(text.count, min(12_000, remaining)); let clipped = amount == text.count ? text : String(text.suffix(amount)); let start = snapshot.range.map { max($0.lowerBound, $0.upperBound - amount) }
                    snapshots.append(ResourceSnapshot(resourceID: snapshot.resourceID, collectedAt: snapshot.collectedAt, text: clipped, isTruncated: snapshot.isTruncated || amount < text.count, errorMessage: snapshot.errorMessage, sourceURL: snapshot.sourceURL, title: snapshot.title, range: start.map { $0..<$0 + amount }, knownDirectory: snapshot.knownDirectory, lifecycle: snapshot.lifecycle, runtimeErrorMessage: snapshot.runtimeErrorMessage, instanceID: snapshot.instanceID)); total += amount
                } else { snapshots.append(snapshot) }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.isShutdown, self.readGenerations[questionID] == token, self.questions[questionID] != nil else { return }
                self.readingQuestions.remove(questionID); self.questions[questionID]?.snapshots = snapshots; self.questions[questionID]?.previewConfirmed = false; self.readTasks[questionID] = nil
                if self.currentQuestionID == questionID { self.previewSnapshots = snapshots; self.previewError = snapshots.first(where: { $0.errorMessage != nil })?.errorMessage; self.isReading = false; self.persist() }
            }
        }
        readTasks[questionID] = readTask!
    }
    @discardableResult func confirmPreview() -> Bool {
        guard !isShutdown, !isReading, !selectedResourceIDs.isEmpty, previewSnapshots.count == selectedResourceIDs.count, previewSnapshots.map(\.resourceID) == selectedResourceIDs, !previewSnapshots.contains(where: { $0.errorMessage != nil }) else { return false }
        setSnapshots(previewSnapshots, confirmed: true); persist(); return true
    }
    func send() {
        guard canSend, let config = configuration, let q = questions[currentQuestionID] else { return }; persist()
        let request = AgentRequest(question: q.draft, snapshots: q.snapshots, configuration: config); let created = AgentRun(id: UUID(), questionID: q.id, request: request, state: .requesting)
        activeRequest = ActiveAgentRequest(questionID: q.id, runID: created.id, request: request); latestRunIDs[q.id] = created.id; run = created; runHistory[created.id] = created; messages.append(AgentMessage(runID: created.id, role: .user, text: request.question)); question = ""; persist(); requestGeneration += 1; let token = requestGeneration
        runTask = Task { [weak self, service] in
            do { try Task.checkCancellation(); let answer = try await service.answer(request: request); try Task.checkCancellation(); await MainActor.run { self?.finish(created, state: .completed(answer), token: token); self?.releaseRequestSlot(created.id) } }
            catch { await MainActor.run { self?.finish(created, state: (error as? AgentServiceError) == .cancelled ? .cancelled : .failed((error as? LocalizedError)?.errorDescription ?? "Agent 请求失败"), token: token); self?.releaseRequestSlot(created.id) } }
        }
    }
    func retry(questionID: UUID? = nil) {
        guard !isShutdown, activeRequest == nil, pendingRequestCleanupID == nil else { return }; let id = questionID ?? currentQuestionID
        guard let runID = latestRunIDs[id], let prior = questions[id]?.runHistory[runID], prior.state.retryable else { return }
        let retried = AgentRun(id: UUID(), questionID: id, request: prior.request, state: .requesting); questions[id]?.runHistory[retried.id] = retried; latestRunIDs[id] = retried.id; activeRequest = ActiveAgentRequest(questionID: id, runID: retried.id, request: prior.request)
        if id == currentQuestionID { run = retried; runHistory[retried.id] = retried }; requestGeneration += 1; let token = requestGeneration
        runTask = Task { [weak self, service] in
            do { try Task.checkCancellation(); let answer = try await service.answer(request: prior.request); try Task.checkCancellation(); await MainActor.run { self?.finish(retried, state: .completed(answer), token: token); self?.releaseRequestSlot(retried.id) } }
            catch { await MainActor.run { self?.finish(retried, state: (error as? AgentServiceError) == .cancelled ? .cancelled : .failed((error as? LocalizedError)?.errorDescription ?? "Agent 请求失败"), token: token); self?.releaseRequestSlot(retried.id) } }
        }
    }
    func cancel(questionID: UUID? = nil) {
        if let questionID { cancelReading(questionID: questionID) } else { cancelReading() }; guard let active = activeRequest, questionID == nil || active.questionID == questionID else { return }
        requestGeneration += 1; pendingRequestCleanupID = active.runID; isCancellingRequest = true; if let task = runTask { retiredTasks.append(task); task.cancel() }; if var r = questions[active.questionID]?.runHistory[active.runID] { r.state = .cancelled; questions[active.questionID]?.runHistory[active.runID] = r; if active.questionID == currentQuestionID { run = r; runHistory[active.runID] = r } }; activeRequest = nil; runTask = nil
    }
    func cancelReading(questionID: UUID? = nil) { let id = questionID ?? currentQuestionID; readGenerations[id, default: 0] += 1; if let task = readTasks[id] { retiredTasks.append(task); task.cancel() }; readTasks[id] = nil; readingQuestions.remove(id); if id == currentQuestionID { readGeneration += 1; readTask = nil; isReading = false } }
    func newChat() { cancel(); cancelAllReads(); readingQuestions.removeAll(); readGenerations.removeAll(); latestRunIDs.removeAll(); let id = currentQuestionID; questions = [id: AgentQuestion(id: id, draft: "", selectedResourceIDs: [], snapshots: [], previewConfirmed: false, messages: [], runHistory: [:])]; questionOrder = [id]; load(questions[id]!) }
    func shutdown() { isShutdown = true; cancel(); cancelAllReads() }
    func shutdownAndWait() async { if let shutdownTask { await shutdownTask.value; return }; isShutdown = true; cancel(); cancelAllReads(); let pending = retiredTasks + [readTask, runTask].compactMap { $0 }; retiredTasks.removeAll(); let task = Task { for t in pending { await t.value } }; shutdownTask = task; await task.value }

    private func finish(_ created: AgentRun, state: AgentRunState, token: Int) { guard !isShutdown, requestGeneration == token, activeRequest?.runID == created.id else { return }; var updated = created; updated.state = state; questions[created.questionID]?.runHistory[created.id] = updated; questions[created.questionID]?.messages.append(contentsOf: { if case let .completed(answer) = state { return [AgentMessage(runID: created.id, role: .assistant, text: answer)] }; return [] }()); latestRunIDs[created.questionID] = created.id; if created.questionID == currentQuestionID { run = updated; runHistory[created.id] = updated; if case let .completed(answer) = state { messages.append(AgentMessage(runID: created.id, role: .assistant, text: answer)) }; persist() }; activeRequest = nil; runTask = nil }
    private func releaseRequestSlot(_ runID: UUID) { if pendingRequestCleanupID == runID { pendingRequestCleanupID = nil; isCancellingRequest = false } }
    private func updateDraft() { guard !isShutdown, questions[currentQuestionID]?.draft != question else { return }; questions[currentQuestionID]?.draft = question }
    private func persist() { guard var q = questions[currentQuestionID] else { return }; q.draft = question; q.selectedResourceIDs = selectedResourceIDs; q.snapshots = previewSnapshots; q.previewConfirmed = q.previewConfirmed && !previewSnapshots.isEmpty; q.messages = messages; q.runHistory = runHistory; questions[currentQuestionID] = q }
    private func load(_ q: AgentQuestion) { question = q.draft; selectedResourceIDs = q.selectedResourceIDs; previewSnapshots = q.snapshots; previewError = q.snapshots.first(where: { $0.errorMessage != nil })?.errorMessage; messages = q.messages; runHistory = q.runHistory; run = latestRunIDs[q.id].flatMap { q.runHistory[$0] }; isReading = readingQuestions.contains(q.id) }
    private func setSnapshots(_ s: [ResourceSnapshot], confirmed: Bool) { questions[currentQuestionID]?.snapshots = s; questions[currentQuestionID]?.previewConfirmed = confirmed }
    private func invalidate() { cancelReading(); previewSnapshots = []; previewError = nil; setSnapshots([], confirmed: false) }
    private func retireRead() { if let readTask { retiredTasks.append(readTask) }; readTask = nil }
    private func cancelAllReads() { let tasks = Array(readTasks.values); tasks.forEach { retiredTasks.append($0); $0.cancel() }; readTasks.removeAll(); readingQuestions.removeAll(); readTask = nil; isReading = false }
}
private extension AgentRunState { var retryable: Bool { if case .failed = self { return true }; if case .cancelled = self { return true }; return false } }
extension AgentController { convenience init(store: ResourceStore, service: ConfiguredResponsesService, configuration: ProviderConfiguration? = nil, reader: (@Sendable (UUID, Int) async -> ResourceSnapshot)? = nil) { self.init(store: store, service: ConfiguredAgentService(credentials: service.credentials, responses: service.provider), configuration: configuration, reader: reader) } }
