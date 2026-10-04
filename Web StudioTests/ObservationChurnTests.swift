import Combine
import Foundation
import Testing

@testable import Web_Studio

/// Every `objectWillChange` emission from a store or model re-evaluates the SwiftUI tree that
/// observes it, so an emission count is the churn measure. Writes that change nothing must not emit;
/// writes that change something must.
@MainActor
struct ObservationChurnTests {
  private final class Emissions { var count = 0 }

  private func watch(_ publisher: ObservableObjectPublisher) -> (Emissions, AnyCancellable) {
    let emissions = Emissions()
    return (emissions, publisher.sink { emissions.count += 1 })
  }

  private func makeWebStore() throws -> (store: ResourceStore, id: UUID, runtime: WebTabRuntime, url: URL) {
    let store = ResourceStore(launchTerminalProcesses: false)
    let id = store.registerWeb(groupID: UUID())
    let runtime = try #require(store.runtime(for: id))
    let url = try #require(URL(string: "https://example.com/page"))
    return (store, id, runtime, url)
  }

  // MARK: Web runtime state -> ResourceStore

  @Test func identicalRuntimeStateWritesPublishNothingAfterTheFirstRealChange() throws {
    let (store, id, runtime, url) = try makeWebStore()
    let (storeEmissions, storeWatch) = watch(store.objectWillChange)
    let (runtimeEmissions, runtimeWatch) = watch(runtime.objectWillChange)
    defer { withExtendedLifetime((storeWatch, runtimeWatch)) {} }

    func applyState() {
      runtime.mutateState {
        $0.url = url
        $0.pageTitle = "Example"
        $0.isLoading = true
        $0.progress = 0.25
        $0.canGoBack = false
        $0.canGoForward = false
        $0.failure = nil
      }
    }
    applyState()
    #expect(runtimeEmissions.count == 1)
    #expect(storeEmissions.count == 1)
    #expect(store.records[id]?.lifecycle == .starting)

    storeEmissions.count = 0
    runtimeEmissions.count = 0
    for _ in 0..<100 {
      applyState()
      // The per-field style the KVO sinks use, one equal value at a time.
      runtime.mutateState { $0.progress = 0.25 }
      runtime.mutateState { $0.pageTitle = "Example" }
      runtime.mutateState { $0.url = url }
      runtime.mutateState { $0.failure = nil }
      runtime.goBack()
      runtime.goForward()
    }
    #expect(runtimeEmissions.count == 0)
    #expect(storeEmissions.count == 0)
    #expect(store.records[id]?.lifecycle == .starting)
  }

  @Test func progressTicksOfALoadingWebResourceDoNotInvalidateTheStore() throws {
    let (store, id, runtime, _) = try makeWebStore()
    runtime.mutateState {
      $0.isLoading = true
      $0.progress = 0.01
    }
    let (storeEmissions, storeWatch) = watch(store.objectWillChange)
    let (runtimeEmissions, runtimeWatch) = watch(runtime.objectWillChange)
    defer { withExtendedLifetime((storeWatch, runtimeWatch)) {} }

    for tick in 2...101 { runtime.mutateState { $0.progress = Double(tick) / 101 } }
    // The runtime's own state genuinely changed each tick, so it publishes each one...
    #expect(runtimeEmissions.count == 100)
    // ...but the resource record derived from it (starting, no error) never changed.
    #expect(storeEmissions.count == 0)
    #expect(store.records[id]?.lifecycle == .starting)
  }

  @Test func lifecycleAndFailureTransitionsStillPropagateToRecords() throws {
    let (store, id, runtime, url) = try makeWebStore()
    let (storeEmissions, storeWatch) = watch(store.objectWillChange)
    defer { withExtendedLifetime(storeWatch) {} }
    func expectOneEmission(_ lifecycle: ResourceLifecycle, error: String? = nil, _ comment: Comment) {
      #expect(storeEmissions.count == 1, comment)
      #expect(store.records[id]?.lifecycle == lifecycle, comment)
      #expect(store.records[id]?.errorMessage == error, comment)
      storeEmissions.count = 0
    }

    runtime.mutateState { $0.isLoading = true }
    expectOneEmission(.starting, "idle -> starting")
    runtime.mutateState {
      $0.isLoading = false
      $0.url = url
    }
    expectOneEmission(.running, "starting -> running")
    let failure = WebNavigationFailure(url: url, message: "offline")
    runtime.mutateState { $0.failure = failure }
    expectOneEmission(.failed, error: "offline", "running -> failed")
    runtime.mutateState { $0.failure = failure }
    #expect(storeEmissions.count == 0, "the same failure again changes nothing")
    runtime.mutateState { $0.failure = WebNavigationFailure(url: url, message: "timeout") }
    expectOneEmission(.failed, error: "timeout", "a different failure message is a real change")
    runtime.mutateState { $0.failure = nil }
    expectOneEmission(.running, "failed -> running once the failure clears")
  }

  // MARK: Titles and the toolbar mirror

  @Test func updateTitleOnlyPublishesWhenTheTitleChanges() throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let id = store.registerWeb(groupID: UUID())
    let (emissions, cancellable) = watch(store.objectWillChange)
    defer { withExtendedLifetime(cancellable) {} }
    let unchanged = try #require(store.records[id]?.title)

    for _ in 0..<100 { store.updateTitle(resourceID: id, title: unchanged) }
    #expect(emissions.count == 0)

    store.updateTitle(resourceID: id, title: "Changed")
    #expect(emissions.count == 1)
    #expect(store.records[id]?.title == "Changed")
    for _ in 0..<100 { store.updateTitle(resourceID: id, title: "Changed") }
    #expect(emissions.count == 1)

    store.updateTitle(resourceID: UUID(), title: "Missing resource")
    #expect(emissions.count == 1)
  }

  @Test func modelStaysQuietForRepeatedStateAndTitleOfBackgroundAndActiveTabs() throws {
    let model = StudioModel(launchTerminalProcesses: false)
    model.newTab()
    let background = model.selectedTabID
    model.newTab()
    let active = model.selectedTabID
    let backgroundRuntime = try #require(model.webRuntimes.runtime(for: background))
    let activeRuntime = try #require(model.webRuntimes.runtime(for: active))
    let url = try #require(URL(string: "https://example.com/page"))
    let (emissions, cancellable) = watch(model.objectWillChange)
    defer { withExtendedLifetime(cancellable) {} }

    // Real changes reach the model: lifecycle, title, and the active tab's toolbar mirror.
    backgroundRuntime.mutateState {
      $0.url = url
      $0.pageTitle = "Background"
      $0.isLoading = true
    }
    #expect(emissions.count > 0)
    #expect(model.webRuntimes.records[background]?.title == "Background")
    #expect(model.webRuntimes.records[background]?.lifecycle == .starting)
    activeRuntime.mutateState {
      $0.url = url
      $0.pageTitle = "Active"
      $0.isLoading = true
      $0.progress = 0.5
    }
    #expect(model.webRuntimes.records[active]?.title == "Active")
    #expect(model.activeWebState.isLoading)
    #expect(model.activeWebState.progress == 0, "progress stays on the runtime, not the window-wide mirror")

    emissions.count = 0
    for _ in 0..<100 {
      backgroundRuntime.mutateState {
        $0.url = url
        $0.pageTitle = "Background"
        $0.isLoading = true
      }
      activeRuntime.mutateState {
        $0.url = url
        $0.pageTitle = "Active"
        $0.isLoading = true
        $0.progress = 0.5
      }
    }
    #expect(emissions.count == 0)

    // Progress of a tab that is not selected only touches the private per-tab mirror.
    for tick in 1...100 { backgroundRuntime.mutateState { $0.progress = Double(tick) / 101 } }
    #expect(emissions.count == 0)

    // A real title change is still one publication.
    backgroundRuntime.mutateState { $0.pageTitle = "Background 2" }
    #expect(emissions.count == 1)
    #expect(model.webRuntimes.records[background]?.title == "Background 2")
  }

  @Test func progressTicksOfTheActiveTabDoNotInvalidateTheModel() throws {
    let model = StudioModel(launchTerminalProcesses: false)
    model.newTab()
    let active = model.selectedTabID
    let runtime = try #require(model.webRuntimes.runtime(for: active))
    let url = try #require(URL(string: "https://example.com/page"))
    runtime.mutateState {
      $0.url = url
      $0.pageTitle = "Active"
      $0.isLoading = true
      $0.progress = 0.01
    }
    #expect(model.activeWebState.isLoading)
    let (modelEmissions, modelWatch) = watch(model.objectWillChange)
    let (runtimeEmissions, runtimeWatch) = watch(runtime.objectWillChange)
    defer { withExtendedLifetime((modelWatch, runtimeWatch)) {} }

    for tick in 2...101 { runtime.mutateState { $0.progress = Double(tick) / 102 } }
    // The progress bar observes the runtime itself, which still publishes every tick...
    #expect(runtimeEmissions.count == 100)
    #expect(runtime.state.progress == 101.0 / 102)
    // ...while the window-wide model only mirrors what the toolbar shows.
    #expect(modelEmissions.count == 0)

    // Toolbar-visible transitions of the active tab still publish.
    runtime.mutateState {
      $0.isLoading = false
      $0.progress = 1
      $0.canGoBack = true
    }
    #expect(modelEmissions.count > 0)
    #expect(model.activeWebState.isLoading == false)
    #expect(model.activeWebState.canGoBack)
  }

  @Test func activeWebStateMirrorPublishesOnlyWhenTheStateChanges() {
    let model = StudioModel(launchTerminalProcesses: false)
    model.newTab()
    let id = model.selectedTabID
    let state = WebNavigationState(pageTitle: "Example", isLoading: true, progress: 0.5)
    let (emissions, cancellable) = watch(model.objectWillChange)
    defer { withExtendedLifetime(cancellable) {} }

    model.recordWebState(tabID: id, state: state)
    #expect(model.activeWebState == state.toolbarMirror)
    let afterFirst = emissions.count
    #expect(afterFirst > 0)
    for _ in 0..<100 { model.recordWebState(tabID: id, state: state) }
    #expect(emissions.count == afterFirst)

    var ticked = state
    ticked.progress = 0.75
    model.recordWebState(tabID: id, state: ticked)
    #expect(emissions.count == afterFirst, "a progress-only change is not mirrored")

    var next = ticked
    next.isLoading = false
    model.recordWebState(tabID: id, state: next)
    #expect(model.activeWebState == next.toolbarMirror)
    #expect(emissions.count > afterFirst)
  }

  // MARK: Terminal directory and lifecycle -> ResourceStore

  @Test func repeatedKnownDirectoryDoesNotRewriteTheRecord() throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let id = store.registerLocalTerminal(groupID: UUID(), directory: "/tmp")
    let session = try #require(store.terminalSession(for: id))
    #expect(session.state == .idle)
    let (emissions, cancellable) = watch(store.objectWillChange)
    var sourceValues = 0
    let sourceWatch = session.$knownDirectory.sink { _ in sourceValues += 1 }
    defer { withExtendedLifetime((cancellable, sourceWatch)) {} }
    sourceValues = 0

    for _ in 0..<100 { session.setKnownDirectory("/tmp") }
    #expect(sourceValues == 100, "the session republishes equal values, as the VT terminal does at frame rate")
    #expect(emissions.count == 0)

    session.setKnownDirectory("/usr")
    #expect(emissions.count == 1)
    #expect(store.records[id]?.location == .localTerminal(directory: "/usr"))
    for _ in 0..<100 { session.setKnownDirectory("/usr") }
    #expect(emissions.count == 1)

    session.setKnownDirectory("/tmp")
    #expect(emissions.count == 2)
    #expect(store.records[id]?.location == .localTerminal(directory: "/tmp"))
  }

  @Test func explicitlyStartedTerminalDirectorySinkAlsoDeduplicates() async throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let id = store.restoreDescriptor(
      ResourceRecord(
        kind: .localTerminal, groupID: UUID(), title: "Terminal",
        location: .localTerminal(directory: "/tmp"), readCapabilities: [.output]))
    _ = try #require(await store.startResource(resourceID: id))
    let session = try #require(store.terminalSession(for: id))
    let (emissions, cancellable) = watch(store.objectWillChange)
    defer { withExtendedLifetime(cancellable) {} }

    for _ in 0..<100 { session.setKnownDirectory("/tmp") }
    #expect(emissions.count == 0)
    session.setKnownDirectory("/usr")
    #expect(emissions.count == 1)
    #expect(store.records[id]?.location == .localTerminal(directory: "/usr"))
    for _ in 0..<100 { session.setKnownDirectory("/usr") }
    #expect(emissions.count == 1)
    await store.endResourceSession(resourceID: id)
  }

  @Test func terminalStateRecordingPublishesOnlyOnRealTransitions() {
    let store = ResourceStore(launchTerminalProcesses: false)
    let id = store.registerLocalTerminal(groupID: UUID(), directory: "/tmp")
    #expect(store.records[id]?.lifecycle == .starting)
    let (emissions, cancellable) = watch(store.objectWillChange)
    defer { withExtendedLifetime(cancellable) {} }

    for _ in 0..<100 { store.recordTerminalState(resourceID: id, state: .starting) }
    #expect(emissions.count == 0)

    store.recordTerminalState(resourceID: id, state: .running)
    #expect(emissions.count == 1)
    #expect(store.records[id]?.lifecycle == .running)
    for _ in 0..<100 { store.recordTerminalState(resourceID: id, state: .running) }
    #expect(emissions.count == 1)

    store.recordTerminalState(resourceID: id, state: .failed("boom"))
    #expect(emissions.count == 2)
    #expect(store.records[id]?.lifecycle == .failed)
    #expect(store.records[id]?.errorMessage == "boom")
    store.recordTerminalState(resourceID: id, state: .exited(0))
    #expect(emissions.count == 3)
    #expect(store.records[id]?.lifecycle == .exited)
    #expect(store.records[id]?.errorMessage == nil)
    store.recordTerminalState(resourceID: id, state: .idle)
    #expect(emissions.count == 3, "idle maps to no record change")
    store.recordTerminalState(resourceID: UUID(), state: .running)
    #expect(emissions.count == 3)
  }

  // MARK: Structural and persisted changes keep notifying

  @Test func genuineStructuralAndPersistedChangesStillPublish() throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let (emissions, cancellable) = watch(store.objectWillChange)
    defer { withExtendedLifetime(cancellable) {} }

    let url = try #require(URL(string: "https://example.com/page"))
    let id = store.registerWeb(groupID: UUID(), destination: url)
    #expect(emissions.count == 1)
    var record = try #require(store.records[id])
    record.customTitle = "Pinned name"
    store.update(record)
    #expect(emissions.count == 2)
    let webID = store.registerWeb(groupID: UUID())
    #expect(emissions.count == 3)
    store.remove(resourceID: webID)
    #expect(emissions.count == 4)
    #expect(store.records[id]?.customTitle == "Pinned name")
  }
}
