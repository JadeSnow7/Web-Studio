import Combine
import Foundation

enum AgentRunState: Equatable, Sendable { case requesting, completed(String), failed(String), cancelled }
struct AgentRun: Identifiable, Equatable, Sendable { let id: UUID; let request: AgentRequest; var state: AgentRunState }

@MainActor final class AgentController: ObservableObject {
    let store: ResourceStore; let service: ConfiguredAgentService
    @Published private(set) var configuration: ProviderConfiguration?
    @Published private(set) var selectedResourceIDs: [UUID] = []
    @Published private(set) var previewSnapshots: [ResourceSnapshot] = []
    @Published var question = ""; @Published private(set) var run: AgentRun?
    /// Display-only transcript for this chat. Requests still carry only the current question and snapshots.
    @Published private(set) var messages: [AgentMessage] = []
    @Published private(set) var runHistory: [UUID: AgentRun] = [:]
    @Published private(set) var isReading = false; @Published private(set) var previewError: String?
    private var previewSelection: [UUID] = []; private var readTask: Task<Void, Never>?; private var runTask: Task<Void, Never>?
    private var readGeneration = 0; private var runGeneration = 0
    private let reader: @Sendable (UUID, Int) async -> ResourceSnapshot
    init(store: ResourceStore, service: ConfiguredAgentService? = nil, configuration: ProviderConfiguration? = nil, reader: (@Sendable (UUID, Int) async -> ResourceSnapshot)? = nil) { self.store = store; self.service = service ?? ConfiguredAgentService(); self.configuration = configuration; self.reader = reader ?? { id, limit in await store.read(resourceID: id, maxCharacters: limit) } }
    func updateConfiguration(_ value: ProviderConfiguration?) { configuration = value }
    var canSend: Bool {
        guard !isReading, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !selectedResourceIDs.isEmpty, previewSnapshots.count == selectedResourceIDs.count,
              previewSelection == selectedResourceIDs,
              previewSnapshots.map(\.resourceID) == selectedResourceIDs,
              !previewSnapshots.contains(where: { $0.errorMessage != nil }), configuration != nil
        else { return false }
        if case .requesting? = run?.state { return false }
        return true
    }
    func addResource(_ id: UUID) { guard store.records[id] != nil, !selectedResourceIDs.contains(id) else { return }; selectedResourceIDs.append(id) }
    func removeResource(_ id: UUID) { selectedResourceIDs.removeAll { $0 == id }; if previewSelection != selectedResourceIDs { previewSnapshots = []; previewSelection = [] } }
    func readPreview() {
        readTask?.cancel(); readGeneration += 1
        let token = readGeneration; let ids = selectedResourceIDs
        previewSnapshots = []; previewSelection = ids; previewError = nil; isReading = true
        readTask = Task { [weak self] in
            var all: [ResourceSnapshot] = []; var total = 0
            for id in ids {
                guard !Task.isCancelled else { return }
                let remaining = 48_000 - total
                guard remaining > 0 else {
                    all.append(.failure(resourceID: id, message: "Preview budget exhausted."))
                    continue
                }
                let snapshot = await self?.reader(id, min(12_000, remaining)) ?? .failure(resourceID: id, message: "Reader unavailable")
                if let text = snapshot.text {
                    let amount = min(text.count, min(12_000, remaining))
                    let clipped = amount == text.count ? text : String(text.suffix(amount))
                    let start = snapshot.range.map { max($0.lowerBound, $0.upperBound - amount) }
                    all.append(ResourceSnapshot(resourceID: snapshot.resourceID, collectedAt: snapshot.collectedAt, text: clipped, isTruncated: snapshot.isTruncated || amount < text.count, errorMessage: snapshot.errorMessage, sourceURL: snapshot.sourceURL, title: snapshot.title, range: start.map { $0..<$0 + amount }, knownDirectory: snapshot.knownDirectory, lifecycle: snapshot.lifecycle, runtimeErrorMessage: snapshot.runtimeErrorMessage))
                    total += amount
                } else { all.append(snapshot) }
            }
            await MainActor.run {
                guard let self, self.readGeneration == token else { return }
                self.previewSnapshots = all; self.previewError = all.first(where: { $0.errorMessage != nil })?.errorMessage; self.isReading = false
            }
        }
    }
    func run(for id: UUID) -> AgentRun? { runHistory[id] }
    func send() { guard canSend, let config = configuration else { return }; runTask?.cancel(); runGeneration += 1; let token = runGeneration; let request = AgentRequest(question: question, snapshots: previewSnapshots, configuration: config); let created = AgentRun(id: UUID(), request: request, state: .requesting); messages.append(AgentMessage(runID: created.id, role: .user, text: request.question)); question = ""; run = created; runHistory[created.id] = created; runTask = Task { [weak self, service] in do { try Task.checkCancellation(); let answer = try await service.answer(request: request); try Task.checkCancellation(); await MainActor.run { guard let self, self.runGeneration == token else { return }; self.run?.state = .completed(answer); self.runHistory[created.id]?.state = .completed(answer); self.messages.append(AgentMessage(runID: created.id, role: .assistant, text: answer)) } } catch { await MainActor.run { guard let self, self.runGeneration == token else { return }; let state: AgentRunState = error as? AgentServiceError == .cancelled ? .cancelled : .failed((error as? LocalizedError)?.errorDescription ?? "Agent request failed"); self.run?.state = state; self.runHistory[created.id]?.state = state } } } }
    func cancel() { readGeneration += 1; runGeneration += 1; readTask?.cancel(); runTask?.cancel(); readTask = nil; runTask = nil; isReading = false; if let active = run, active.state == .requesting { run?.state = .cancelled; runHistory[active.id]?.state = .cancelled } }
    func cancelReading() { readGeneration += 1; readTask?.cancel(); readTask = nil; isReading = false }
    func newChat() {
        cancel()
        question = ""
        selectedResourceIDs = []
        previewSnapshots = []
        previewSelection = []
        previewError = nil
        run = nil
        runHistory = [:]
        messages = []
    }
    func retry() { guard let prior = run else { return }; guard prior.state == .cancelled || ifCaseFailed(prior.state) else { return }; runTask?.cancel(); runGeneration += 1; let token = runGeneration; let retried = AgentRun(id: UUID(), request: prior.request, state: .requesting); run = retried; runHistory[retried.id] = retried; runTask = Task { [weak self, service] in do { try Task.checkCancellation(); let answer = try await service.answer(request: prior.request); try Task.checkCancellation(); await MainActor.run { guard let self, self.runGeneration == token else { return }; self.run?.state = .completed(answer); self.runHistory[retried.id]?.state = .completed(answer); self.messages.append(AgentMessage(runID: retried.id, role: .assistant, text: answer)) } } catch { await MainActor.run { guard let self, self.runGeneration == token else { return }; let state: AgentRunState = error as? AgentServiceError == .cancelled ? .cancelled : .failed((error as? LocalizedError)?.errorDescription ?? "Agent request failed"); self.run?.state = state; self.runHistory[retried.id]?.state = state } } } }
    private func ifCaseFailed(_ state: AgentRunState) -> Bool { if case .failed = state { return true }; return false }
    func shutdown() { cancel() }
}

extension AgentController {
    convenience init(store: ResourceStore, service: ConfiguredResponsesService, configuration: ProviderConfiguration? = nil, reader: (@Sendable (UUID, Int) async -> ResourceSnapshot)? = nil) {
        self.init(store: store, service: ConfiguredAgentService(credentials: service.credentials, responses: service.provider), configuration: configuration, reader: reader)
    }
}
