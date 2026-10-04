import Foundation
import Testing

@testable import Web_Studio

private actor TerminalCloseGate {
  var entered = false
  var released = false
  func wait() async {
    entered = true
    while !released { await Task.yield() }
  }
  func release() { released = true }
}

@MainActor
struct WorkspaceTerminalActionsTests {
  @Test func modelEndKeepsLayoutAndRejectsStaleCapture() async throws {
    let model = StudioModel(launchTerminalProcesses: false)
    let resourceID = model.webRuntimes.registerLocalTerminal(
      groupID: model.session.id, directory: FileManager.default.temporaryDirectory.path)
    model.layout = WorkspaceLayout(primary: PaneState(resourceID: resourceID, isFocused: true))
    let capture = try #require(model.captureTerminalEnd(resourceID: resourceID))
    let oldInstance = capture.instanceID
    #expect(
      await model.endResourceSession(
        owner: capture.owner, resourceID: resourceID,
        expectedInstanceID: oldInstance))
    #expect(model.layout.primary.resourceID == resourceID)
    let newInstance = try #require(await model.webRuntimes.startResource(resourceID: resourceID))
    #expect(newInstance != oldInstance)
    #expect(
      await model.endResourceSession(
        owner: capture.owner, resourceID: resourceID,
        expectedInstanceID: oldInstance) == false)
    await model.webRuntimes.shutdown()
  }

  @Test func endingCapturedWorkspaceSurvivesSwitchToB() async throws {
    let model = StudioModel(launchTerminalProcesses: false)
    model.newTab()
    let a = model.session
    let terminalA = model.webRuntimes.registerLocalTerminal(
      groupID: a.id, directory: FileManager.default.temporaryDirectory.path)
    let bID = try #require(model.createWorkspace(name: "B", isTemporary: true))
    let bResource = model.webRuntimes.registerLocalTerminal(
      groupID: bID, directory: FileManager.default.temporaryDirectory.path)
    model.selectedTabID = bResource
    model.selectWorkspace(a.id)
    let capture = try #require(model.captureTerminalEnd(resourceID: terminalA))
    let gate = TerminalCloseGate()
    a.resourceStore.closeAndWaitHook = { await gate.wait() }
    let ending = Task { @MainActor in
      await model.endResourceSession(
        owner: capture.owner, resourceID: capture.resourceID,
        expectedInstanceID: capture.instanceID)
    }
    for _ in 0..<100 where !(await gate.entered) { await Task.yield() }
    #expect(await gate.entered)
    #expect(
      await model.endResourceSession(
        owner: capture.owner, resourceID: capture.resourceID,
        expectedInstanceID: capture.instanceID) == false)
    model.selectWorkspace(bID)
    #expect(model.session.id == bID)
    #expect(model.webRuntimes.records[bResource]?.runtimeInstanceID != nil)
    #expect(model.webRuntimes.activeTerminalSessionCount == 1)
    await gate.release()
    _ = await ending.value
    #expect(a.resourceStore.records[terminalA]?.lifecycle == .exited)
    #expect(model.webRuntimes.records[bResource]?.id == bResource)
    await a.resourceStore.shutdown()
    await model.webRuntimes.shutdown()
  }

  @Test func endSessionKeepsDescriptorAndLayoutThenCreatesNewInstance() async throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let resourceID = store.restoreDescriptor(
      ResourceRecord(
        kind: .localTerminal, groupID: UUID(), title: "终端",
        location: .localTerminal(directory: FileManager.default.temporaryDirectory.path)))
    let first = try #require(await store.startResource(resourceID: resourceID))
    await store.endResourceSession(resourceID: resourceID)
    #expect(store.records[resourceID] != nil)
    #expect(store.order.contains(resourceID))
    let second = try #require(await store.startResource(resourceID: resourceID))
    #expect(first != second)
    #expect(store.records[resourceID]?.id == resourceID)
    await store.shutdown()
  }

  @Test func directoryURLStartRepairsTheSameResource() async throws {
    let store = ResourceStore(launchTerminalProcesses: false)
    let resourceID = store.restoreDescriptor(
      ResourceRecord(
        kind: .localTerminal, groupID: UUID(), title: "终端",
        location: .localTerminal(directory: "/definitely/missing/web-studio")))
    #expect(await store.startResource(resourceID: resourceID) == nil)
    let url = FileManager.default.temporaryDirectory
    let instance = try #require(await store.startResource(resourceID: resourceID, directoryURL: url))
    #expect(store.records[resourceID]?.id == resourceID)
    #expect(store.records[resourceID]?.lifecycle == .starting)
    #expect(store.records[resourceID]?.runtimeInstanceID == instance)
    if case .localTerminal(let path) = store.records[resourceID]?.location {
      #expect(path == url.path)
    } else {
      Issue.record("expected a local terminal descriptor")
    }
    await store.shutdown()
  }

  @Test func invalidDirectoryURLPreservesOriginalPath() async throws {
    let original = "/definitely/missing/web-studio-original"
    let store = ResourceStore(launchTerminalProcesses: false)
    let resourceID = store.restoreDescriptor(
      ResourceRecord(
        kind: .localTerminal, groupID: UUID(), title: "终端",
        location: .localTerminal(directory: original), lifecycle: .failed))
    #expect(
      await store.startResource(
        resourceID: resourceID,
        directoryURL: URL(fileURLWithPath: "/definitely/missing/web-studio-new")) == nil)
    if case .localTerminal(let path) = store.records[resourceID]?.location {
      #expect(path == original)
    } else {
      Issue.record("expected original terminal path")
    }
    #expect(store.terminalFactoryCreationCount == 0)
    await store.shutdown()
  }

  @Test func modelRepairRejectsInvalidDirectoryWithoutReplacingDescriptor() async throws {
    let model = StudioModel(launchTerminalProcesses: false)
    let original = "/definitely/missing/web-studio-original"
    let id = model.webRuntimes.restoreDescriptor(
      ResourceRecord(
        kind: .localTerminal, groupID: model.session.id, title: "终端",
        location: .localTerminal(directory: original)))
    #expect(await model.webRuntimes.startResource(resourceID: id) == nil)
    #expect(model.webRuntimes.records[id]?.lifecycle == .failed)
    #expect(
      await model.repairTerminalDirectory(
        owner: model.session, resourceID: id,
        expectedInstanceID: nil, directoryURL: URL(fileURLWithPath: "/definitely/missing/new")) == false)
    if case .localTerminal(let path) = model.webRuntimes.records[id]?.location {
      #expect(path == original)
    } else {
      Issue.record("expected original terminal path")
    }
    #expect(model.webRuntimes.terminalFactoryCreationCount == 0)
    await model.webRuntimes.shutdown()
  }

  @Test func modelRepairValidDirectoryStartsSameResource() async throws {
    let model = StudioModel(launchTerminalProcesses: false)
    let original = "/definitely/missing/web-studio-original"
    let id = model.webRuntimes.restoreDescriptor(
      ResourceRecord(
        kind: .localTerminal, groupID: model.session.id, title: "终端",
        location: .localTerminal(directory: original)))
    #expect(await model.webRuntimes.startResource(resourceID: id) == nil)
    let chosen = FileManager.default.temporaryDirectory
    #expect(
      await model.repairTerminalDirectory(
        owner: model.session, resourceID: id,
        expectedInstanceID: nil, directoryURL: chosen))
    #expect(model.webRuntimes.records[id]?.runtimeInstanceID != nil)
    if case .localTerminal(let path) = model.webRuntimes.records[id]?.location {
      #expect(path == chosen.path)
    } else {
      Issue.record("expected repaired terminal path")
    }
    await model.webRuntimes.shutdown()
  }

  @Test func modelRepairRejectsClosedOwner() async throws {
    let model = StudioModel(launchTerminalProcesses: false)
    let id = model.webRuntimes.restoreDescriptor(
      ResourceRecord(
        kind: .localTerminal, groupID: model.session.id, title: "终端",
        location: .localTerminal(directory: "/definitely/missing/web-studio")))
    #expect(await model.webRuntimes.startResource(resourceID: id) == nil)
    let owner = model.session
    await owner.close()
    #expect(
      await model.repairTerminalDirectory(
        owner: owner, resourceID: id,
        expectedInstanceID: nil, directoryURL: FileManager.default.temporaryDirectory) == false)
  }

  @Test func splitPickerRejectsOldWorkspaceAndFocusesMountedResource() throws {
    let model = StudioModel(launchTerminalProcesses: false)
    model.newTab()
    let firstResource = model.selectedTabID
    model.split()
    #expect(model.splitPickerPresented)
    let firstID = model.session.id
    let otherID = try #require(model.createWorkspace(name: "B", isTemporary: true))
    model.newTab()
    let primaryB = model.selectedTabID
    model.splitPickerWorkspaceID = firstID
    model.splitPickerPresented = true
    model.chooseSplitResource(firstResource)
    #expect(model.layout.secondary == nil)
    model.newTab()
    let primaryB2 = model.selectedTabID
    model.split()
    let b1 = primaryB
    model.chooseSplitResource(b1)
    let secondary = try #require(model.layout.secondary)
    let secondaryID = secondary.resourceID
    model.focusPane(model.layout.primary.id)
    model.splitPickerWorkspaceID = otherID
    model.chooseSplitResource(b1)
    #expect(model.layout.secondary?.resourceID == secondaryID)
    #expect(model.layout.primary.resourceID == primaryB2)
    model.showResourceOnRight(primaryB2)
    #expect(model.layout.secondary?.resourceID == secondaryID)
  }
}
