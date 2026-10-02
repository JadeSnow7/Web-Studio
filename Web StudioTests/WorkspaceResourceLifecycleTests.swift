import Foundation
import Testing
@testable import Web_Studio

private actor CloseGate {
    private var released = false
    private var waiting = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var hookCalls = 0
    func wait() async {
        if released { return }
        hookCalls += 1
        waiting += 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in continuations.append(continuation) }
    }
    func release() { released = true; continuations.forEach { $0.resume() }; continuations.removeAll() }
    var waiterCount: Int { waiting }
}

private actor CompletionFlag {
    private(set) var isComplete = false
    func complete() { isComplete = true }
}

@MainActor
struct WorkspaceResourceLifecycleTests {
    @Test func restoringDescriptorsDoesNotCreateRuntime() async throws {
        let store = ResourceStore(launchTerminalProcesses: false)
        let groupID = UUID()
        let resourceID = UUID()
        let record = ResourceRecord(id: resourceID, kind: .localTerminal, groupID: groupID,
                                    title: "Restored terminal",
                                    location: .localTerminal(directory: FileManager.default.temporaryDirectory.path),
                                    lifecycle: .running, readCapabilities: [.output])

        #expect(store.restoreDescriptor(record) == resourceID)
        #expect(store.records[resourceID]?.lifecycle == .idle)
        #expect(store.terminalFactoryCreationCount == 0)
        #expect(store.activeTerminalSessionCount == 0)
        let snapshot = await store.read(resourceID: resourceID)
        #expect(snapshot.errorMessage == "资源暂时无法读取。")
        #expect(store.terminalFactoryCreationCount == 0)
    }

    @Test func explicitStartIsIdempotentAndEndKeepsDescription() async throws {
        let store = ResourceStore(launchTerminalProcesses: false)
        let resourceID = store.restoreDescriptor(ResourceRecord(kind: .localTerminal,
            groupID: UUID(), title: "Terminal", location: .localTerminal(directory: FileManager.default.temporaryDirectory.path)))

        async let first = store.startResource(resourceID: resourceID)
        async let second = store.startResource(resourceID: resourceID)
        let (firstID, secondID) = await (first, second)
        #expect(firstID != nil)
        #expect(firstID == secondID)
        #expect(store.terminalFactoryCreationCount == 1)

        await store.endResourceSession(resourceID: resourceID)
        #expect(store.records[resourceID] != nil)
        #expect(store.activeTerminalSessionCount == 0)
        let nextID = await store.startResource(resourceID: resourceID)
        #expect(nextID != nil)
        #expect(nextID != firstID)
        await store.shutdown()
    }

    @Test func invalidDirectoryDoesNotInvokeFactory() async throws {
        let store = ResourceStore(launchTerminalProcesses: false)
        let id = store.restoreDescriptor(ResourceRecord(kind: .localTerminal,
            groupID: UUID(), title: "Missing", location: .localTerminal(directory: "/definitely/missing/web-studio")))

        #expect(await store.startResource(resourceID: id) == nil)
        #expect(store.terminalFactoryCreationCount == 0)
        #expect(store.records[id]?.lifecycle == .failed)
    }

    @Test func restoringWebAndSSHLeavesAllRuntimesIdle() async throws {
        let store = ResourceStore(launchTerminalProcesses: false)
        let groupID = UUID()
        let webID = store.restoreDescriptor(ResourceRecord(kind: .web, groupID: groupID, title: "Web", location: .web(URL(string: "https://example.com")), lifecycle: .running))
        let sshID = store.restoreDescriptor(ResourceRecord(kind: .sshTerminal, groupID: groupID, title: "SSH", location: .ssh(host: "example.com", user: "dev", port: 22), lifecycle: .running))

        #expect(store.records[webID]?.lifecycle == .idle)
        #expect(store.records[sshID]?.lifecycle == .idle)
        #expect(store.activeRuntimeCount == 0)
        #expect(store.activeTerminalSessionCount == 0)
        #expect(store.terminalFactoryCreationCount == 0)
        #expect(store.existingRuntime(for: webID) == nil)
    }

    @Test func endingTwiceSharesOneControlledCleanupTask() async throws {
        let store = ResourceStore(launchTerminalProcesses: false)
        let id = store.restoreDescriptor(ResourceRecord(kind: .localTerminal, groupID: UUID(), title: "Terminal", location: .localTerminal(directory: FileManager.default.temporaryDirectory.path)))
        #expect(await store.startResource(resourceID: id) != nil)
        let gate = CloseGate()
        store.closeAndWaitHook = { await gate.wait() }
        async let first: Void = store.endResourceSession(resourceID: id)
        async let second: Void = store.endResourceSession(resourceID: id)
        while await gate.waiterCount < 1 { await Task.yield() }
        #expect(await gate.hookCalls == 1)
        #expect(store.activeTerminalSessionCount == 1)
        await gate.release()
        await first
        await second
        #expect(store.activeTerminalSessionCount == 0)
    }

    @Test func removeWaitsForExistingEndBeforeAllowingIdentityReuse() async throws {
        let store = ResourceStore(launchTerminalProcesses: false)
        let id = store.restoreDescriptor(ResourceRecord(kind: .localTerminal, groupID: UUID(), title: "Terminal", location: .localTerminal(directory: FileManager.default.temporaryDirectory.path)))
        #expect(await store.startResource(resourceID: id) != nil)
        let gate = CloseGate()
        store.closeAndWaitHook = { await gate.wait() }
        let done = CompletionFlag()
        let ending = Task { await store.endResourceSession(resourceID: id); await done.complete() }
        while await gate.waiterCount < 1 { await Task.yield() }
        store.remove(resourceID: id)
        #expect(store.records[id] == nil)
        #expect(await store.startResource(resourceID: id) == nil)
        #expect(await done.isComplete == false)
        await gate.release()
        await ending.value
        #expect(await done.isComplete)
    }

    @Test func shutdownWaitsForExistingEnd() async throws {
        let store = ResourceStore(launchTerminalProcesses: false)
        let id = store.restoreDescriptor(ResourceRecord(kind: .localTerminal, groupID: UUID(), title: "Terminal", location: .localTerminal(directory: FileManager.default.temporaryDirectory.path)))
        #expect(await store.startResource(resourceID: id) != nil)
        let gate = CloseGate()
        store.closeAndWaitHook = { await gate.wait() }
        let done = CompletionFlag()
        let ending = Task { await store.endResourceSession(resourceID: id); await done.complete() }
        while await gate.waiterCount < 1 { await Task.yield() }
        let shutdown = Task { await store.shutdown() }
        await Task.yield()
        #expect(await store.startResource(resourceID: id) == nil)
        #expect(await done.isComplete == false)
        await gate.release()
        await ending.value
        await shutdown.value
        #expect(await done.isComplete)
        #expect(store.records[id] == nil)
    }

    @Test func synchronousRegistrationRejectsMissingDirectoryWithoutFactory() {
        let store = ResourceStore(launchTerminalProcesses: false)
        let missingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("web-studio-missing-\(UUID().uuidString)").path
        #expect(!FileManager.default.fileExists(atPath: missingDirectory))
        let id = store.registerLocalTerminal(groupID: UUID(), directory: missingDirectory)
        #expect(store.terminalFactoryCreationCount == 0)
        #expect(store.records[id]?.lifecycle == .failed)
        #expect(store.terminalSession(for: id) == nil)
    }

    @Test func directoryValidationFollowsDirectorySymlinkOnly() async throws {
        let store = ResourceStore(launchTerminalProcesses: false)
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("web-studio-links-\(UUID().uuidString)")
        let realDirectory = root.appendingPathComponent("directory")
        let realFile = root.appendingPathComponent("file")
        let directoryLink = root.appendingPathComponent("directory-link")
        let fileLink = root.appendingPathComponent("file-link")
        let missingLink = root.appendingPathComponent("missing-link")
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        #expect(fileManager.createFile(atPath: realFile.path, contents: Data()))
        try fileManager.createSymbolicLink(at: directoryLink, withDestinationURL: realDirectory)
        try fileManager.createSymbolicLink(at: fileLink, withDestinationURL: realFile)
        try fileManager.createSymbolicLink(at: missingLink, withDestinationURL: root.appendingPathComponent("does-not-exist"))

        let validID = store.registerLocalTerminal(groupID: UUID(), directory: directoryLink.path)
        #expect(store.records[validID]?.lifecycle == .starting)
        #expect(store.terminalSession(for: validID) != nil)
        #expect(store.terminalFactoryCreationCount == 1)

        let fileID = store.registerLocalTerminal(groupID: UUID(), directory: fileLink.path)
        let missingID = store.registerLocalTerminal(groupID: UUID(), directory: missingLink.path)
        #expect(store.records[fileID]?.lifecycle == .failed)
        #expect(store.records[missingID]?.lifecycle == .failed)
        #expect(store.terminalSession(for: fileID) == nil)
        #expect(store.terminalSession(for: missingID) == nil)
        #expect(store.terminalFactoryCreationCount == 1)
        await store.shutdown()
    }

    @Test func snapshotsKeepTheInstanceIdentityTheyCaptured() async throws {
        let store = ResourceStore(launchTerminalProcesses: false)
        let id = store.restoreDescriptor(ResourceRecord(kind: .localTerminal, groupID: UUID(), title: "Terminal", location: .localTerminal(directory: FileManager.default.temporaryDirectory.path)))
        let firstID = try #require(await store.startResource(resourceID: id))
        let first = await store.read(resourceID: id)
        await store.endResourceSession(resourceID: id)
        let secondID = try #require(await store.startResource(resourceID: id))
        let second = await store.read(resourceID: id)
        #expect(first.instanceID != nil)
        #expect(second.instanceID != nil)
        #expect(first.instanceID == firstID)
        #expect(second.instanceID == secondID)
        #expect(first.instanceID != second.instanceID)
        await store.shutdown()
    }
}
