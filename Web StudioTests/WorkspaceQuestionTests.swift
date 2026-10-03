import Foundation
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
