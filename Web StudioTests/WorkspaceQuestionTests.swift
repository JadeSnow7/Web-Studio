import Combine
import Foundation
import SwiftUI
import Testing

@testable import Web_Studio

private actor QuestionProvider: ResponsesProvider {
  var requests: [AgentRequest] = []
  var continuations: [CheckedContinuation<String, Error>] = []
  func answer(request: AgentRequest, apiKey: String) async throws -> String {
    requests.append(request)
    return try await withCheckedThrowingContinuation { continuations.append($0) }
  }
  func resolve(_ text: String) {
    let pending = continuations
    continuations.removeAll()
    pending.forEach { $0.resume(returning: text) }
  }
  func count() -> Int { requests.count }
  func all() -> [AgentRequest] { requests }
}

@MainActor
struct WorkspaceQuestionTests {

  @Test(arguments: [true, false])
  func closedControllerRejectsDirectDraftEdits(waitForShutdown: Bool) async {
    let controller = AgentController(store: ResourceStore(launchTerminalProcesses: false))
    let id = controller.currentQuestionID
    controller.question = "draft before shutdown"
    #expect(controller.questions[id]?.draft == "draft before shutdown")
    if waitForShutdown {
      await controller.shutdownAndWait()
    } else {
      controller.shutdown()
    }
    controller.question = "edit after shutdown"
    #expect(controller.question == "draft before shutdown")
    #expect(controller.questions[id]?.draft == "draft before shutdown")
  }

  @Test func newChatAfterShutdownClearsQuestionStateWithoutReopeningController() async throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let resource = store.registerWeb(groupID: UUID())
    let provider = QuestionProvider()
    let controller = AgentController(
      store: store, service: ConfiguredResponsesService(credentials: TestQuestionCredentials(), provider: provider),
      configuration: try ProviderConfiguration(model: "test"),
      reader: { id, _ in questionStateSnapshot(id) })
    let id = controller.currentQuestionID
    controller.addResource(resource)
    controller.question = "sent draft"
    controller.readPreview()
    try await waitForQuestionState { !controller.isReading }
    #expect(controller.confirmPreview())
    controller.send()
    for _ in 0..<1000 {
      if await provider.count() == 1 { break }
      await Task.yield()
    }
    try #require(await provider.count() == 1)
    await provider.resolve("completed answer")
    try await waitForQuestionState { controller.run?.state == .completed("completed answer") }
    controller.question = "unsent draft"
    #expect(!controller.messages.isEmpty)
    #expect(!controller.question.isEmpty)
    #expect(!controller.previewSnapshots.isEmpty)
    #expect(!controller.runHistory.isEmpty)
    let populated = try #require(controller.questions[id])
    #expect(!populated.messages.isEmpty)
    #expect(!populated.draft.isEmpty)
    #expect(!populated.snapshots.isEmpty)
    #expect(!populated.runHistory.isEmpty)

    await controller.shutdownAndWait()
    controller.newChat()
    #expect(controller.messages.isEmpty)
    #expect(controller.question.isEmpty)
    #expect(controller.previewSnapshots.isEmpty)
    #expect(controller.runHistory.isEmpty)
    #expect(controller.run == nil)
    let cleared = try #require(controller.questions[id])
    #expect(cleared.messages.isEmpty)
    #expect(cleared.draft.isEmpty)
    #expect(cleared.snapshots.isEmpty)
    #expect(cleared.runHistory.isEmpty)
    #expect(!cleared.previewConfirmed)
    #expect(controller.newQuestion() == nil)
    #expect(!controller.canSend)
    controller.send()
    #expect(controller.run == nil)
    #expect(controller.activeRequest == nil)
    #expect(controller.questions[id] == cleared)
  }

  @Test func emptyPreviewCannotBeConfirmed() {
    let controller = AgentController(store: ResourceStore(launchTerminalProcesses: false))
    #expect(controller.previewSnapshots.isEmpty)
    #expect(!controller.confirmPreview())
    #expect(controller.questions[controller.currentQuestionID]?.previewConfirmed == false)
  }

  @Test func rereadingConfirmedPreviewClearsSnapshotsAndConfirmationUntilCompletion() async throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let resource = store.registerWeb(groupID: UUID())
    let gate = QuestionReaderGate()
    let controller = AgentController(
      store: store, configuration: try ProviderConfiguration(model: "test"),
      reader: { id, _ in await gate.read(id, snapshot: questionStateSnapshot(id)) })
    controller.addResource(resource)
    controller.question = "draft"
    controller.readPreview()
    try await waitForQuestionReader(gate, resource: resource)
    await gate.release(resource, snapshot: questionStateSnapshot(resource))
    try await waitForQuestionState { !controller.isReading }
    #expect(controller.confirmPreview())
    #expect(controller.canSend)

    controller.readPreview()
    #expect(controller.isReading)
    #expect(controller.previewSnapshots.isEmpty)
    #expect(controller.questions[controller.currentQuestionID]?.snapshots.isEmpty == true)
    #expect(controller.questions[controller.currentQuestionID]?.previewConfirmed == false)
    #expect(!controller.canSend)
    try await waitForQuestionReader(gate, resource: resource)
    await gate.release(resource, snapshot: questionStateSnapshot(resource, text: "fresh"))
    try await waitForQuestionState { !controller.isReading }
    #expect(controller.previewSnapshots.first?.text == "fresh")
    #expect(controller.questions[controller.currentQuestionID]?.previewConfirmed == false)
    await controller.shutdownAndWait()
  }

  @Test(arguments: [true, false])
  func resourceSelectionChangeInvalidatesConfirmedPreview(adding: Bool) async throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let first = store.registerWeb(groupID: UUID())
    let second = store.registerWeb(groupID: UUID())
    let controller = AgentController(
      store: store, configuration: try ProviderConfiguration(model: "test"),
      reader: { id, _ in questionStateSnapshot(id) })
    controller.addResource(first)
    controller.question = "draft"
    controller.readPreview()
    try await waitForQuestionState { !controller.isReading }
    #expect(controller.confirmPreview())
    #expect(controller.canSend)
    if adding {
      controller.addResource(second)
      #expect(controller.selectedResourceIDs == [first, second])
    } else {
      controller.removeResource(first)
      #expect(controller.selectedResourceIDs.isEmpty)
    }
    #expect(controller.previewSnapshots.isEmpty)
    #expect(controller.questions[controller.currentQuestionID]?.snapshots.isEmpty == true)
    #expect(controller.questions[controller.currentQuestionID]?.previewConfirmed == false)
    #expect(!controller.canSend)
    await controller.shutdownAndWait()
  }

  @Test func sendFreezesDraftBeforeClearingProjectedAndStoredDraft() async throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let resource = store.registerWeb(groupID: UUID())
    let provider = QuestionProvider()
    let controller = AgentController(
      store: store, service: ConfiguredResponsesService(credentials: TestQuestionCredentials(), provider: provider),
      configuration: try ProviderConfiguration(model: "test"),
      reader: { id, _ in questionStateSnapshot(id) })
    let id = controller.currentQuestionID
    controller.addResource(resource)
    controller.question = "draft before send"
    controller.readPreview()
    try await waitForQuestionState { !controller.isReading }
    #expect(controller.confirmPreview())
    controller.send()
    #expect(controller.activeRequest?.request.question == "draft before send")
    #expect(controller.messages.last?.role == .user)
    #expect(controller.messages.last?.text == "draft before send")
    #expect(controller.questions[id]?.messages.last?.text == "draft before send")
    #expect(controller.question.isEmpty)
    #expect(controller.questions[id]?.draft.isEmpty == true)
    for _ in 0..<1000 {
      if await provider.count() == 1 { break }
      await Task.yield()
    }
    try #require(await provider.count() == 1)
    #expect(await provider.all().first?.question == "draft before send")
    await provider.resolve("answer")
    await controller.shutdownAndWait()
  }

  @Test func observedObjectDraftBindingPublishesAndWritesQuestionState() {
    let controller = AgentController(store: ResourceStore(launchTerminalProcesses: false))
    let observation = QuestionStateObservation()
    let watch = controller.objectWillChange.sink { observation.didChange = true }
    defer { withExtendedLifetime(watch) {} }
    let binding = ObservedObject(wrappedValue: controller).projectedValue.question
    binding.wrappedValue = "binding draft"
    #expect(observation.didChange)
    #expect(binding.wrappedValue == "binding draft")
    #expect(controller.question == "binding draft")
    #expect(controller.questions[controller.currentQuestionID]?.draft == "binding draft")
  }

  @Test func backgroundQuestionReadCompletionPublishesAndKeepsCurrentProjection() async throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let resource = store.registerWeb(groupID: UUID())
    let gate = QuestionReaderGate()
    let controller = AgentController(
      store: store, configuration: try ProviderConfiguration(model: "test"),
      reader: { id, _ in await gate.read(id, snapshot: questionStateSnapshot(id)) })
    let first = controller.currentQuestionID
    controller.addResource(resource)
    controller.readPreview()
    try await waitForQuestionReader(gate, resource: resource)
    let second = try #require(controller.newQuestion())
    controller.question = "current draft"
    let observation = QuestionStateObservation()
    let watch = controller.objectWillChange.sink { observation.didChange = true }
    defer { withExtendedLifetime(watch) {} }
    await gate.release(resource, snapshot: questionStateSnapshot(resource, text: "background"))
    try await waitForQuestionState { controller.questions[first]?.snapshots.first?.text == "background" }
    #expect(observation.didChange)
    #expect(controller.currentQuestionID == second)
    #expect(controller.question == "current draft")
    #expect(controller.previewSnapshots.isEmpty)
    #expect(controller.questions[second]?.snapshots.isEmpty == true)
    controller.selectQuestion(first)
    #expect(controller.previewSnapshots.first?.text == "background")
    await controller.shutdownAndWait()
  }
  @Test func questionOrderAppendsWithoutReorderingOrDeletingOldQuestions() async throws {
    let controller = AgentController(store: ResourceStore(launchTerminalProcesses: false))
    let first = controller.currentQuestionID
    let second = try #require(controller.newQuestion())
    let third = try #require(controller.newQuestion())
    #expect(controller.questionOrder == [first, second, third])
    controller.selectQuestion(first)
    #expect(controller.questionOrder == [first, second, third])
    #expect(controller.questions[second] != nil)
    #expect(controller.questions[third] != nil)
  }

  @Test func newQuestionKeepsIndependentDraftsAndSelection() async throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let resource = store.registerWeb(groupID: UUID())
    let controller = AgentController(
      store: store, configuration: try ProviderConfiguration(model: "test"),
      reader: { id, _ in
        ResourceSnapshot(
          resourceID: id, collectedAt: Date(), text: "fixture", isTruncated: false, errorMessage: nil, sourceURL: nil,
          title: "fixture", range: 0..<7)
      })
    controller.addResource(resource)
    controller.question = "A draft"
    let firstID = controller.currentQuestionID
    let secondID = try #require(controller.newQuestion())
    #expect(firstID != secondID)
    #expect(controller.question.isEmpty)
    controller.question = "B draft"
    controller.selectQuestion(firstID)
    #expect(controller.question == "A draft")
    #expect(controller.selectedResourceIDs == [resource])
    controller.selectQuestion(secondID)
    #expect(controller.question == "B draft")
    #expect(controller.selectedResourceIDs.isEmpty)
  }

  @Test func previewRequiresExplicitConfirmationBeforeSend() async throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let resource = store.registerWeb(groupID: UUID())
    let controller = AgentController(
      store: store, configuration: try ProviderConfiguration(model: "test"),
      reader: { id, _ in
        ResourceSnapshot(
          resourceID: id, collectedAt: Date(), text: "fixture", isTruncated: false, errorMessage: nil, sourceURL: nil,
          title: "fixture", range: 0..<7)
      })
    controller.addResource(resource)
    controller.question = "Question"
    controller.readPreview()
    for _ in 0..<1000 {
      if !controller.isReading { break }
      await Task.yield()
    }
    #expect(!controller.canSend)
    #expect(controller.confirmPreview())
    #expect(controller.canSend)
  }

  @Test func oneSpaceRequestSlotBlocksAnotherQuestionUntilCompletion() async throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let resource = store.registerWeb(groupID: UUID())
    let provider = QuestionProvider()
    let service = ConfiguredResponsesService(credentials: TestQuestionCredentials(), provider: provider)
    let controller = AgentController(
      store: store, service: service, configuration: try ProviderConfiguration(model: "test"),
      reader: { id, _ in
        ResourceSnapshot(
          resourceID: id, collectedAt: Date(), text: "fixture", isTruncated: false, errorMessage: nil, sourceURL: nil,
          title: "fixture", range: 0..<7)
      })
    controller.addResource(resource)
    controller.question = "A"
    controller.readPreview()
    for _ in 0..<1000 {
      if !controller.isReading { break }
      await Task.yield()
    }
    #expect(controller.confirmPreview())
    controller.send()
    for _ in 0..<1000 {
      if await provider.count() == 1 { break }
      await Task.yield()
    }
    let firstID = controller.currentQuestionID
    let secondID = try #require(controller.newQuestion())
    controller.selectQuestion(secondID)
    controller.question = "B"
    controller.addResource(resource)
    controller.readPreview()
    for _ in 0..<1000 {
      if !controller.isReading { break }
      await Task.yield()
    }
    #expect(controller.confirmPreview())
    #expect(controller.activeRequest?.questionID != secondID)
    #expect(!controller.canSend)
    await provider.resolve("A answer")
    for _ in 0..<1000 {
      if controller.activeRequest == nil { break }
      await Task.yield()
    }
    #expect(controller.canSend)
    #expect(controller.questions[firstID]?.messages.contains(where: { $0.text == "A answer" }) == true)
    #expect(controller.questions[secondID]?.messages.contains(where: { $0.text == "A answer" }) != true)
    controller.selectQuestion(firstID)
    #expect(controller.run?.state == .completed("A answer"))
  }

  @Test func cancelledProviderRetainsSlotUntilItsTaskExits() async throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let resource = store.registerWeb(groupID: UUID())
    let provider = QuestionProvider()
    let service = ConfiguredResponsesService(credentials: TestQuestionCredentials(), provider: provider)
    let controller = AgentController(
      store: store, service: service, configuration: try ProviderConfiguration(model: "test"),
      reader: { id, _ in
        ResourceSnapshot(
          resourceID: id, collectedAt: Date(), text: "fixture", isTruncated: false, errorMessage: nil, sourceURL: nil,
          title: "fixture", range: 0..<7)
      })
    controller.addResource(resource)
    controller.question = "A"
    controller.readPreview()
    for _ in 0..<1000 {
      if !controller.isReading { break }
      await Task.yield()
    }
    #expect(controller.confirmPreview())
    controller.send()
    for _ in 0..<1000 {
      if await provider.count() == 1 { break }
      await Task.yield()
    }
    controller.cancel()
    let second = try #require(controller.newQuestion())
    controller.selectQuestion(second)
    controller.addResource(resource)
    controller.question = "B"
    controller.readPreview()
    for _ in 0..<1000 {
      if !controller.isReading { break }
      await Task.yield()
    }
    #expect(controller.confirmPreview())
    #expect(!controller.canSend)
    await provider.resolve("late A")
    for _ in 0..<1000 {
      if controller.canSend { break }
      await Task.yield()
    }
    #expect(controller.canSend)
    controller.send()
    for _ in 0..<1000 {
      if await provider.count() == 2 { break }
      await Task.yield()
    }
    #expect(await provider.count() == 2)
    await provider.resolve("B answer")
    await controller.shutdownAndWait()
  }

  @Test func readCompletionReturnsToOriginQuestionAfterSwitch() async throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let resource = store.registerWeb(groupID: UUID())
    let gate = QuestionReaderGate()
    let controller = AgentController(
      store: store, configuration: try ProviderConfiguration(model: "test"),
      reader: { id, _ in
        await gate.read(
          id,
          snapshot: ResourceSnapshot(
            resourceID: id, collectedAt: Date(), text: "A", isTruncated: false, errorMessage: nil, sourceURL: nil,
            title: "A", range: 0..<1))
      })
    let firstID = controller.currentQuestionID
    controller.addResource(resource)
    controller.readPreview()
    for _ in 0..<1000 {
      if await gate.hasWaiter(resource) { break }
      await Task.yield()
    }
    let secondID = try #require(controller.newQuestion())
    controller.selectQuestion(secondID)
    await gate.release(
      resource,
      snapshot: ResourceSnapshot(
        resourceID: resource, collectedAt: Date(), text: "A", isTruncated: false, errorMessage: nil, sourceURL: nil,
        title: "A", range: 0..<1))
    for _ in 0..<1000 {
      if controller.questions[firstID]?.snapshots.isEmpty == false { break }
      await Task.yield()
    }
    controller.selectQuestion(firstID)
    #expect(controller.previewSnapshots.first?.text == "A")
  }

  @Test func selectionChangeInvalidatesLatePreview() async throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let first = store.registerWeb(groupID: UUID())
    let second = store.registerWeb(groupID: UUID())
    let gate = QuestionReaderGate()
    let controller = AgentController(
      store: store, configuration: try ProviderConfiguration(model: "test"),
      reader: { id, _ in
        await gate.read(
          id,
          snapshot: ResourceSnapshot(
            resourceID: id, collectedAt: Date(), text: "late", isTruncated: false, errorMessage: nil, sourceURL: nil,
            title: "late", range: 0..<4))
      })
    controller.addResource(first)
    controller.readPreview()
    for _ in 0..<1000 {
      if await gate.hasWaiter(first) { break }
      await Task.yield()
    }
    controller.addResource(second)
    await gate.release(
      first,
      snapshot: ResourceSnapshot(
        resourceID: first, collectedAt: Date(), text: "late", isTruncated: false, errorMessage: nil, sourceURL: nil,
        title: "late", range: 0..<4))
    for _ in 0..<1000 {
      if !controller.isReading { break }
      await Task.yield()
    }
    #expect(controller.previewSnapshots.isEmpty)
    #expect(!controller.canSend)
  }

  @Test func shutdownCancelsAndWaitsForReadsFromTwoQuestions() async throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let first = store.registerWeb(groupID: UUID())
    let second = store.registerWeb(groupID: UUID())
    let gate = QuestionReaderGate()
    let controller = AgentController(
      store: store, configuration: try ProviderConfiguration(model: "test"),
      reader: { id, _ in
        await gate.read(
          id,
          snapshot: ResourceSnapshot(
            resourceID: id, collectedAt: Date(), text: "held", isTruncated: false, errorMessage: nil, sourceURL: nil,
            title: "held", range: 0..<4))
      })
    controller.addResource(first)
    controller.readPreview()
    for _ in 0..<1000 {
      if await gate.hasWaiter(first) { break }
      await Task.yield()
    }
    let secondQuestion = try #require(controller.newQuestion())
    controller.selectQuestion(secondQuestion)
    controller.addResource(second)
    controller.readPreview()
    for _ in 0..<1000 {
      if await gate.hasWaiter(second) { break }
      await Task.yield()
    }
    var finished = false
    let shutdown = Task { @MainActor in
      await controller.shutdownAndWait()
      finished = true
    }
    await Task.yield()
    #expect(controller.newQuestion() == nil)
    #expect(!finished)
    await gate.release(
      first,
      snapshot: ResourceSnapshot(
        resourceID: first, collectedAt: Date(), text: "held", isTruncated: false, errorMessage: nil, sourceURL: nil,
        title: "held", range: 0..<4))
    await Task.yield()
    #expect(!finished)
    await gate.release(
      second,
      snapshot: ResourceSnapshot(
        resourceID: second, collectedAt: Date(), text: "held", isTruncated: false, errorMessage: nil, sourceURL: nil,
        title: "held", range: 0..<4))
    await shutdown.value
    #expect(finished)
  }

  @Test func retryReusesFrozenRequestWithoutRereading() async throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let resource = store.registerWeb(groupID: UUID())
    let provider = RetryQuestionProvider()
    let reads = ReadCount()
    let original = try ProviderConfiguration(model: "original")
    let controller = AgentController(
      store: store, service: ConfiguredResponsesService(credentials: TestQuestionCredentials(), provider: provider),
      configuration: original,
      reader: { id, _ in
        await reads.add()
        return ResourceSnapshot(
          resourceID: id, collectedAt: Date(), text: "frozen", isTruncated: false, errorMessage: nil, sourceURL: nil,
          title: "fixture", range: 0..<6)
      })
    controller.addResource(resource)
    controller.question = "original"
    controller.readPreview()
    for _ in 0..<1000 {
      if !controller.isReading { break }
      await Task.yield()
    }
    #expect(controller.confirmPreview())
    controller.send()
    for _ in 0..<1000 {
      if controller.run?.state != .requesting { break }
      await Task.yield()
    }
    controller.question = "changed"
    controller.updateConfiguration(try ProviderConfiguration(model: "changed"))
    controller.retry()
    for _ in 0..<1000 {
      if await provider.count() == 2 { break }
      await Task.yield()
    }
    #expect(await reads.count == 1)
    let requests = await provider.requests
    let readyRequests = try #require(requests.count == 2 ? requests : nil)
    #expect(readyRequests[0] == readyRequests[1])
  }
}

private actor TestQuestionCredentials: CredentialStore {
  func save(apiKey: String, for endpoint: URL) async throws {}
  func read(for endpoint: URL) async throws -> String? { "test-key" }
  func delete(for endpoint: URL) async throws {}
}

private actor QuestionReaderGate {
  var waiting: [UUID: CheckedContinuation<ResourceSnapshot, Never>] = [:]
  func read(_ id: UUID, snapshot: ResourceSnapshot) async -> ResourceSnapshot {
    await withCheckedContinuation { waiting[id] = $0 }
  }
  func release(_ id: UUID, snapshot: ResourceSnapshot) {
    waiting[id]?.resume(returning: snapshot)
    waiting[id] = nil
  }
  func hasWaiter(_ id: UUID) -> Bool { waiting[id] != nil }
}

private actor ReadCount {
  var count = 0
  func add() { count += 1 }
}
private actor RetryQuestionProvider: ResponsesProvider {
  var requests: [AgentRequest] = []
  func answer(request: AgentRequest, apiKey: String) async throws -> String {
    requests.append(request)
    if requests.count == 1 { throw AgentServiceError.http(500) }
    return "retried"
  }
  func count() -> Int { requests.count }
}

private func questionStateSnapshot(_ id: UUID, text: String = "fixture") -> ResourceSnapshot {
  ResourceSnapshot(
    resourceID: id, collectedAt: Date(), text: text, isTruncated: false, errorMessage: nil, sourceURL: nil,
    title: "fixture", range: 0..<text.count)
}

@MainActor
private final class QuestionStateObservation {
  var didChange = false
}

@MainActor
private func waitForQuestionState(_ ready: () -> Bool) async throws {
  for _ in 0..<1000 {
    if ready() { return }
    await Task.yield()
  }
  try #require(ready())
}

private func waitForQuestionReader(_ gate: QuestionReaderGate, resource: UUID) async throws {
  for _ in 0..<1000 {
    if await gate.hasWaiter(resource) { return }
    await Task.yield()
  }
  try #require(await gate.hasWaiter(resource))
}
