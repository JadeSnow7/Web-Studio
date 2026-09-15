import Foundation
import Testing
import WebKit
import SwiftTerm
@testable import Web_Studio

@MainActor
struct ResourceReadTests {
    private func waitFor(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return predicate()
    }

    private func waitForDOM(_ runtime: WebTabRuntime) async -> Bool {
        for _ in 0..<100 {
            // WebKit publishes isLoading after the document has committed and its
            // DOM is available to the same isolated world used by readSnapshot.
            if runtime.webView.url != nil && !runtime.state.isLoading {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
    @Test func terminalReadUsesLatestBoundedUnicodeText() async {
        let model = StudioModel(launchTerminalProcesses: false)
        let id = model.webRuntimes.registerLocalTerminal(groupID: model.selectedGroupID, directory: "/tmp")
        let session = model.webRuntimes.terminalSession(for: id)
        session?.terminalView.feed(byteArray: Array("前置\n最后你好".utf8)[...])
        let snapshot = await model.webRuntimes.read(resourceID: id, maxCharacters: 4)
        #expect(snapshot.text?.hasSuffix("你好") == true)
        #expect(snapshot.isTruncated)
        #expect(snapshot.knownDirectory == "/tmp")
    }

    @Test func closedResourceReadIsExplicitFailure() async {
        let model = StudioModel(launchTerminalProcesses: false)
        let id = model.selectedTabID
        model.webRuntimes.remove(resourceID: id)
        let snapshot = await model.webRuntimes.read(resourceID: id)
        #expect(snapshot.text == nil)
        #expect(snapshot.errorMessage?.contains("closed") == true)
    }

    @Test func emptyWebReadReportsUnavailable() async {
        let model = StudioModel(launchTerminalProcesses: false)
        let snapshot = await model.webRuntimes.read(resourceID: model.selectedTabID)
        #expect(snapshot.text == nil || snapshot.text == "")
    }

    @Test func actualWKWebViewHTMLReadIsBounded() async throws {
        let runtime = WebTabRuntime(resourceID: UUID())
        let base = URL(string: "https://local.web-studio.test/page")!
        runtime.webView.loadHTMLString("<body>前置 👨‍👩‍👧‍👦 末尾</body>", baseURL: base)
        #expect(await waitForDOM(runtime))
        let snapshot = await runtime.readSnapshot(resourceID: runtime.resourceID, maxCharacters: 5)
        #expect(snapshot.errorMessage == nil)
        #expect(snapshot.resourceID == runtime.resourceID)
        #expect(snapshot.text?.hasPrefix("前置 ") == true)
        #expect(snapshot.text?.contains("👨‍👩‍👧‍👦") == true)
        #expect(snapshot.text == String("前置 👨‍👩‍👧‍👦 末尾".prefix(5)))
        #expect(snapshot.isTruncated)
        #expect(snapshot.sourceURL == base)
        #expect(snapshot.range == 0..<5)
        #expect(snapshot.text?.count ?? 0 <= 5)
    }

    @Test func sameDocumentPushStateUpdatesRecordWithoutReplacingWebView() async throws {
        let model = StudioModel(launchTerminalProcesses: false)
        let id = model.selectedTabID
        let runtime = model.webRuntimes.runtime(for: id)!
        let base = URL(string: "https://local.web-studio.test/start")!
        runtime.webView.loadHTMLString("<body><span id='sentinel'>kept</span></body>", baseURL: base)
        #expect(await waitForDOM(runtime))
        let originalView = runtime.webView
        let changed = URL(string: "https://local.web-studio.test/next")!
        _ = try? await runtime.webView.evaluateJavaScript("history.pushState({}, '', '/next')", in: nil, contentWorld: .defaultClient)
        #expect(await waitFor { model.webRuntimes.records[id]?.location == .web(changed) })
        #expect(runtime.webView === originalView)
        let sentinel = try? await runtime.webView.evaluateJavaScript("document.querySelector('#sentinel')?.textContent", in: nil, contentWorld: .defaultClient)
        #expect(sentinel as? String == "kept")
    }

    @Test func cancelledReadReturnsFailure() async {
        let runtime = WebTabRuntime(resourceID: UUID())
        let base = URL(string: "https://local.web-studio.test/cancel")!
        runtime.webView.loadHTMLString("<body>cancel me</body>", baseURL: base)
        #expect(await waitForDOM(runtime))
        let task = Task { await runtime.readSnapshot(resourceID: runtime.resourceID) }
        task.cancel()
        let snapshot = await task.value
        #expect(snapshot.text == nil)
        #expect(snapshot.errorMessage == "Page read was cancelled.")
    }

    @Test func navigationDuringReadIsReportedAsFailure() async throws {
        let runtime = WebTabRuntime(resourceID: UUID())
        let base = URL(string: "https://local.web-studio.test/busy")!
        runtime.webView.loadHTMLString("<body>busy</body>", baseURL: base)
        #expect(await waitForDOM(runtime))
        _ = try? await runtime.webView.evaluateJavaScript("Object.defineProperty(document.body, 'innerText', {get() { const end = Date.now() + 250; while (Date.now() < end) {} return 'busy'; }})", in: nil, contentWorld: .defaultClient)
        let task = Task { await runtime.readSnapshot(resourceID: runtime.resourceID) }
        try? await Task.sleep(for: .milliseconds(20))
        runtime.load(URL(string: "about:blank")!)
        let snapshot = await task.value
        #expect(snapshot.text == nil)
        #expect(snapshot.errorMessage?.contains("navigated") == true)
    }

    @Test func terminalAndSSHMetadataRemainDistinct() async {
        let model = StudioModel(launchTerminalProcesses: false)
        let sshID = model.webRuntimes.registerSSH(groupID: model.selectedGroupID, host: "host.example", user: "dev", port: 2222)
        let ssh = model.webRuntimes.terminalSession(for: sshID)!; ssh.setKnownDirectory("/tmp")
        model.renameResource(sshID, title: "Saved SSH")
        let sshSnapshot = await model.webRuntimes.read(resourceID: sshID)
        #expect(sshSnapshot.title == "Saved SSH")
        #expect(sshSnapshot.sourceURL?.scheme == "ssh")
        #expect(sshSnapshot.sourceURL?.host == "host.example")
        #expect(sshSnapshot.sourceURL?.user == "dev")
        #expect(sshSnapshot.sourceURL?.port == 2222)
        if case .ssh = model.webRuntimes.records[sshID]?.location { } else { #expect(false) }

        let localID = model.webRuntimes.registerLocalTerminal(groupID: model.selectedGroupID, directory: "/tmp")
        let local = model.webRuntimes.terminalSession(for: localID)!; local.hostCurrentDirectoryUpdate(source: local.terminalView, directory: "file:///tmp/work")
        #expect(model.webRuntimes.records[localID]?.location == .localTerminal(directory: "/tmp/work"))
        local.terminalView.feed(byteArray: Array("  indented\n".utf8)[...])
        let localSnapshot = await model.webRuntimes.read(resourceID: localID)
        #expect(localSnapshot.text?.contains("  indented") == true)
    }
}
