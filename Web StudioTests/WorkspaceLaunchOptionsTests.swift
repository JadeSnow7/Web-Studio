import Foundation
import Testing
@testable import Web_Studio

private actor LaunchTestCredentials: CredentialStore {
    func save(apiKey: String, for endpoint: URL) async throws {}
    func read(for endpoint: URL) async throws -> String? { nil }
    func delete(for endpoint: URL) async throws {}
}

struct WorkspaceLaunchOptionsTests {
    @Test func explicitRootWinsOverXCTestDetection() {
        let root = URL(fileURLWithPath: "/private/tmp/web-studio-b1", isDirectory: true)
        let options = StudioLaunchOptions.resolve(
            arguments: ["Web Studio", "--workspace-config-root", root.path],
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"])
        #expect(options.isXCTest)
        #expect(options.workspaceConfigRoot == root)
    }

    @Test func XCTestWithoutRootRemainsMemoryOnly() {
        let options = StudioLaunchOptions.resolve(
            arguments: ["Web Studio"],
            environment: ["XCTestSessionIdentifier": "test-session"])
        #expect(options.isXCTest)
        #expect(options.workspaceConfigRoot == nil)
    }

    @Test func nonTestHostWithoutRootUsesNormalMode() {
        let options = StudioLaunchOptions.resolve(arguments: ["Web Studio"], environment: [:])
        #expect(!options.isXCTest)
        #expect(options.workspaceConfigRoot == nil)
    }

    @Test func providerIsolationIsStableAndScoped() {
        let root = URL(fileURLWithPath: "/private/tmp/web-studio-b1-a", isDirectory: true)
        let otherRoot = URL(fileURLWithPath: "/private/tmp/web-studio-b1-b", isDirectory: true)
        #expect(StudioLaunchOptions.scopedProviderDefaultsSuite(root: root) == StudioLaunchOptions.scopedProviderDefaultsSuite(root: root))
        #expect(StudioLaunchOptions.scopedProviderDefaultsSuite(root: root) != StudioLaunchOptions.scopedProviderDefaultsSuite(root: otherRoot))
        #expect(StudioLaunchOptions.scopedProviderDefaultsSuite(root: root, explicitSuite: "test.provider") == "test.provider")
        #expect(StudioLaunchOptions.scopedKeychainService(root: root) != "com.huaodong.web-studio.provider")
    }

    @Test func providerIsolationDoesNotDependOnRootExistence() throws {
        let root = URL(fileURLWithPath: "/private/tmp/web-studio-launch-token-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        #expect(!fileManager.fileExists(atPath: root.path))
        defer { try? fileManager.removeItem(at: root) }

        let suiteBefore = StudioLaunchOptions.scopedProviderDefaultsSuite(root: root)
        let serviceBefore = StudioLaunchOptions.scopedKeychainService(root: root)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let relaunchedRoot = URL(fileURLWithPath: root.path, isDirectory: true)
        let suiteAfter = StudioLaunchOptions.scopedProviderDefaultsSuite(root: relaunchedRoot)
        let serviceAfter = StudioLaunchOptions.scopedKeychainService(root: relaunchedRoot)

        #expect(suiteBefore == suiteAfter)
        #expect(serviceBefore == serviceAfter)
    }

    @Test @MainActor func workspaceSessionSharesInjectedCredentialsWithAgentService() {
        let credentials = LaunchTestCredentials()
        let defaults = UserDefaults(suiteName: "com.huaodong.web-studio.launch-test.\(UUID().uuidString)")!
        let provider = ProviderSettings(credentials: credentials, defaults: defaults)
        let session = WorkspaceSession(launchTerminalProcesses: false, providerSettings: provider)
        #expect((session.providerSettings.credentials as AnyObject) === (session.agentController.service.credentials as AnyObject))
    }
}
