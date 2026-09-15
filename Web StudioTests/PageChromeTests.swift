import Foundation
import Testing
import WebKit
@testable import Web_Studio

@MainActor
struct PageChromeTests {
    @Test func activeRuntimeLookupDoesNotCreateAnUnshownRuntime() {
        let model = StudioModel(launchTerminalProcesses: false)
        let id = model.selectedTabID

        #expect(model.webRuntimes.existingRuntime(for: id) == nil)
        #expect(model.activeWebRuntime == nil)
        #expect(model.webRuntimes.existingRuntime(for: id) == nil)
    }

    @Test func windowlessCaptureIsInertAfterTeardown() async {
        let runtime = WebTabRuntime(resourceID: UUID())
        await runtime.capturePageChromeSnapshot()
        #expect(runtime.chromeSnapshot == nil)

        runtime.teardown()
        #expect(runtime.chromeSnapshot == nil)
        await runtime.capturePageChromeSnapshot()
        #expect(runtime.chromeSnapshot == nil)
    }
}
