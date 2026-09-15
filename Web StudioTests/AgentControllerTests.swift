import Foundation
import Testing
@testable import Web_Studio

private actor ControllerCredentials: CredentialStore {
    func save(apiKey: String, for endpoint: URL) async throws {}
    func read(for endpoint: URL) async throws -> String? { "test-key" }
    func delete(for endpoint: URL) async throws {}
}
private struct ControllerProvider: ResponsesProvider {
    let answerText: String
    func answer(request: AgentRequest, apiKey: String) async throws -> String { answerText }
}
private actor SequentialProvider: ResponsesProvider {
    var requests: [AgentRequest] = []
    func answer(request: AgentRequest, apiKey: String) async throws -> String { requests.append(request); return "answer-\(requests.count)" }
    func allRequests() -> [AgentRequest] { requests }
}

private actor ControlledProvider: ResponsesProvider {
    var requests: [AgentRequest] = []
    var waiting: [CheckedContinuation<String, Error>] = []
    func answer(request: AgentRequest, apiKey: String) async throws -> String {
        requests.append(request)
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }
    func resolve(_ value: String = "late") { let continuations = waiting; waiting.removeAll(); continuations.forEach { $0.resume(returning: value) } }
    func requestCount() -> Int { requests.count }
}
private actor ReadCounter { var ids: [UUID] = []; func add(_ id: UUID) { ids.append(id) } }
private actor PendingReader {
    var continuation: CheckedContinuation<ResourceSnapshot, Never>?
    func read(_ snapshot: ResourceSnapshot) async -> ResourceSnapshot { await withCheckedContinuation { continuation = $0 } }
    func resume(_ snapshot: ResourceSnapshot) { continuation?.resume(returning: snapshot); continuation = nil }
}
private actor RetryProvider: ResponsesProvider {
    var requests: [AgentRequest] = []
    func answer(request: AgentRequest, apiKey: String) async throws -> String {
        requests.append(request)
        if requests.count == 1 { throw AgentServiceError.http(500) }
        return "retried"
    }
    func allRequests() -> [AgentRequest] { requests }
}

private func testSnapshot(_ id: UUID, text: String = "snapshot") -> ResourceSnapshot {
    ResourceSnapshot(resourceID: id, collectedAt: Date(), text: text, isTruncated: false, errorMessage: nil, sourceURL: nil, title: "Resource", range: 0..<text.count)
}

struct AgentControllerTests {
    @Test @MainActor func newChatClearsTranscriptAndIgnoresLateResponse() async throws {
        let store = ResourceStore(launchTerminalProcesses: false); let id = store.registerLocalTerminal(groupID: UUID(), directory: "/tmp")
        let provider = ControlledProvider(); let config = try ProviderConfiguration(model: "m")
        let controller = AgentController(store: store, service: ConfiguredResponsesService(credentials: ControllerCredentials(), provider: provider), configuration: config, reader: { id, _ in testSnapshot(id) })
        controller.addResource(id); controller.question = "old"; controller.readPreview(); try await Task.sleep(for: .milliseconds(20)); controller.send()
        for _ in 0..<20 { if await provider.requestCount() == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        controller.newChat(); await provider.resolve("late"); try await Task.sleep(for: .milliseconds(30))
        #expect(controller.messages.isEmpty); #expect(controller.run == nil); #expect(controller.question.isEmpty)
    }

    @Test @MainActor func newChatIgnoresLatePreviewRead() async throws {
        let store = ResourceStore(launchTerminalProcesses: false); let id = store.registerLocalTerminal(groupID: UUID(), directory: "/tmp")
        let pending = PendingReader(); let controller = AgentController(store: store, configuration: try ProviderConfiguration(model: "m"), reader: { id, _ in await pending.read(testSnapshot(id)) })
        controller.addResource(id); controller.readPreview(); try await Task.sleep(for: .milliseconds(20)); controller.newChat()
        await pending.resume(testSnapshot(id, text: "late")); try await Task.sleep(for: .milliseconds(30))
        #expect(controller.messages.isEmpty); #expect(controller.previewSnapshots.isEmpty); #expect(!controller.isReading)
    }

    @Test @MainActor func sequentialRunsDisplayTranscriptAndKeepIndividualPayloads() async throws {
        let store = ResourceStore(launchTerminalProcesses: false); let id = store.registerLocalTerminal(groupID: UUID(), directory: "/tmp")
        let provider = SequentialProvider(); let config = try ProviderConfiguration(model: "m")
        let controller = AgentController(store: store, service: ConfiguredResponsesService(credentials: ControllerCredentials(), provider: provider), configuration: config, reader: { id, _ in testSnapshot(id) })
        controller.addResource(id); controller.question = "first"; controller.readPreview(); try await Task.sleep(for: .milliseconds(20)); controller.send(); try await Task.sleep(for: .milliseconds(30))
        controller.question = "second"; controller.send(); try await Task.sleep(for: .milliseconds(30))
        #expect(controller.messages.map(\.text) == ["first", "answer-1", "second", "answer-2"])
        #expect(controller.messages[0].runID == controller.messages[1].runID)
        #expect(controller.messages[2].runID == controller.messages[3].runID)
        #expect(controller.messages[0].runID != controller.messages[2].runID)
        let requests = await provider.allRequests(); #expect(requests.map(\.question) == ["first", "second"])
    }

    @Test @MainActor func previewIsExplicitAndSendKeepsSnapshotAfterResourceRemoval() async throws {
        let store = ResourceStore(launchTerminalProcesses: false); let id = store.registerLocalTerminal(groupID: UUID(), directory: "/tmp")
        let config = try ProviderConfiguration(model: "test-model")
        let controller = AgentController(store: store, service: ConfiguredResponsesService(credentials: ControllerCredentials(), provider: ControllerProvider(answerText: "ok")), configuration: config)
        controller.addResource(id); controller.question = "What?"; controller.readPreview()
        try await Task.sleep(for: .milliseconds(50)); #expect(controller.previewSnapshots.count == 1)
        controller.send(); store.remove(resourceID: id); try await Task.sleep(for: .milliseconds(50)); #expect(controller.run?.state == .completed("ok"))
    }

    @Test @MainActor func unconfiguredSendDoesNotCreateRun() {
        let store = ResourceStore(launchTerminalProcesses: false); let controller = AgentController(store: store); controller.question = "q"; controller.send(); #expect(controller.run == nil)
    }

    @Test @MainActor func delayedRunRetainsOriginalRequestAfterSelectionAndDeletion() async throws {
        let store = ResourceStore(launchTerminalProcesses: false); let id = store.registerLocalTerminal(groupID: UUID(), directory: "/tmp")
        let provider = ControlledProvider(); let config = try ProviderConfiguration(model: "test-model")
        let controller = AgentController(store: store, service: ConfiguredResponsesService(credentials: ControllerCredentials(), provider: provider), configuration: config, reader: { id, _ in testSnapshot(id) })
        controller.addResource(id); controller.question = "original"; controller.readPreview(); try await Task.sleep(for: .milliseconds(20)); controller.send(); try await Task.sleep(for: .milliseconds(20)); controller.removeResource(id); store.remove(resourceID: id); await provider.resolve("answer"); try await Task.sleep(for: .milliseconds(50))
        #expect(controller.run?.request.question == "original"); #expect(controller.run?.state == .completed("answer")); #expect(controller.run?.request.snapshots.first?.resourceID == id)
    }

    @Test @MainActor func cancelIgnoresLateProviderResult() async throws {
        let store = ResourceStore(launchTerminalProcesses: false); let id = store.registerLocalTerminal(groupID: UUID(), directory: "/tmp"); let provider = ControlledProvider(); let config = try ProviderConfiguration(model: "test-model")
        let controller = AgentController(store: store, service: ConfiguredResponsesService(credentials: ControllerCredentials(), provider: provider), configuration: config, reader: { id, _ in testSnapshot(id) })
        controller.addResource(id); controller.question = "cancel"; controller.readPreview(); try await Task.sleep(for: .milliseconds(20)); controller.send()
        for _ in 0..<20 { if await provider.requestCount() == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(await provider.requestCount() == 1); controller.cancel(); await provider.resolve(); try await Task.sleep(for: .milliseconds(30)); #expect(controller.run?.state == .cancelled)
    }

    @Test @MainActor func previewBudgetStopsReaderAtFortyEightThousand() async throws {
        let store = ResourceStore(launchTerminalProcesses: false); let counter = ReadCounter(); var ids: [UUID] = []
        for _ in 0..<5 { ids.append(store.registerLocalTerminal(groupID: UUID(), directory: "/tmp")) }
        let controller = AgentController(store: store, configuration: try ProviderConfiguration(model: "m"), reader: { id, _ in await counter.add(id); return testSnapshot(id, text: String(repeating: "x", count: 12_000)) })
        ids.forEach { controller.addResource($0) }; controller.readPreview(); try await Task.sleep(for: .milliseconds(50)); #expect(controller.previewSnapshots.count == 5); #expect(await counter.ids.count == 4); #expect(controller.previewSnapshots.last?.errorMessage?.contains("budget") == true)
    }

    @Test @MainActor func retryUsesOriginalRequestAfterDraftChanges() async throws {
        let store = ResourceStore(launchTerminalProcesses: false)
        let id = store.registerLocalTerminal(groupID: UUID(), directory: "/tmp")
        let provider = RetryProvider(); let original = try ProviderConfiguration(model: "original")
        let controller = AgentController(store: store, service: ConfiguredResponsesService(credentials: ControllerCredentials(), provider: provider), configuration: original, reader: { id, _ in testSnapshot(id) })
        controller.addResource(id); controller.question = "original"; controller.readPreview(); try await Task.sleep(for: .milliseconds(30)); controller.send(); try await Task.sleep(for: .milliseconds(30))
        #expect(controller.run?.state == .failed("Provider request failed (HTTP 500)."))
        controller.question = "changed"; controller.updateConfiguration(try ProviderConfiguration(model: "changed")); controller.removeResource(id); store.remove(resourceID: id); controller.retry();
        for _ in 0..<20 { if await provider.allRequests().count == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let requests = try #require(await provider.allRequests().count == 2 ? await provider.allRequests() : nil); #expect(requests[1] == requests[0]); #expect(controller.question == "changed")
    }

    @Test @MainActor func failedReaderPreventsSend() async throws {
        let store = ResourceStore(launchTerminalProcesses: false); let id = store.registerLocalTerminal(groupID: UUID(), directory: "/tmp")
        let controller = AgentController(store: store, configuration: try ProviderConfiguration(model: "m"), reader: { id, _ in .failure(resourceID: id, message: "read failed") })
        controller.addResource(id); controller.question = "q"; controller.readPreview(); try await Task.sleep(for: .milliseconds(30)); #expect(!controller.canSend); controller.send(); #expect(controller.run == nil)
    }

    @Test @MainActor func pendingReaderCannotSendAndCancelledLateReadIsIgnored() async throws {
        let store = ResourceStore(launchTerminalProcesses: false); let id = store.registerLocalTerminal(groupID: UUID(), directory: "/tmp")
        let pending = PendingReader(); let controller = AgentController(store: store, configuration: try ProviderConfiguration(model: "m"), reader: { id, _ in await pending.read(testSnapshot(id)) })
        controller.addResource(id); controller.question = "q"; controller.readPreview(); try await Task.sleep(for: .milliseconds(20)); #expect(controller.isReading); #expect(!controller.canSend); controller.send(); #expect(controller.run == nil); controller.cancel(); await pending.resume(testSnapshot(id, text: "late")); try await Task.sleep(for: .milliseconds(30)); #expect(controller.previewSnapshots.isEmpty); #expect(!controller.isReading)
    }

    @Test @MainActor func runningRequestSurvivesPreviewCancellation() async throws {
        let store = ResourceStore(launchTerminalProcesses: false); let id = store.registerLocalTerminal(groupID: UUID(), directory: "/tmp")
        let provider = ControlledProvider(); let pending = PendingReader(); let config = try ProviderConfiguration(model: "m")
        let controller = AgentController(store: store, service: ConfiguredResponsesService(credentials: ControllerCredentials(), provider: provider), configuration: config, reader: { id, _ in await pending.read(testSnapshot(id)) })
        controller.addResource(id); controller.question = "q"; controller.readPreview(); try await Task.sleep(for: .milliseconds(20)); await pending.resume(testSnapshot(id)); try await Task.sleep(for: .milliseconds(30)); controller.send()
        for _ in 0..<20 { if await provider.requestCount() == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        controller.readPreview(); try await Task.sleep(for: .milliseconds(10)); controller.cancelReading(); #expect(controller.run?.state == .requesting)
        await pending.resume(testSnapshot(id, text: "late")); await provider.resolve("done"); try await Task.sleep(for: .milliseconds(40)); #expect(controller.run?.state == .completed("done")); #expect(controller.previewSnapshots.isEmpty)
    }

    @Test @MainActor func readerReturnsOversizedTextIsCapped() async throws {
        let store = ResourceStore(launchTerminalProcesses: false); let id = store.registerLocalTerminal(groupID: UUID(), directory: "/tmp")
        let controller = AgentController(store: store, configuration: try ProviderConfiguration(model: "m"), reader: { id, _ in testSnapshot(id, text: String(repeating: "x", count: 50_000)) })
        controller.addResource(id); controller.readPreview(); try await Task.sleep(for: .milliseconds(40)); let snapshot = try #require(controller.previewSnapshots.first); #expect(snapshot.text?.count == 12_000); #expect(snapshot.isTruncated); #expect(snapshot.range?.count == 12_000)
    }
}
