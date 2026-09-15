import Foundation
import Testing
@testable import Web_Studio

private actor SettingsCredentials: CredentialStore {
    var values: [URL: String] = [:]
    var failSave = false
    func save(apiKey: String, for endpoint: URL) async throws { if failSave { throw AgentServiceError.missingCredential }; values[endpoint] = apiKey }
    func read(for endpoint: URL) async throws -> String? { values[endpoint] }
    func delete(for endpoint: URL) async throws { values[endpoint] = nil }
}

@MainActor
struct ProviderSettingsTests {
    private func settings(_ credentials: SettingsCredentials) -> (ProviderSettings, UserDefaults, String) {
        let suite = "WebStudio.ProviderTests.\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!; defaults.removePersistentDomain(forName: suite)
        return (ProviderSettings(credentials: credentials, defaults: defaults), defaults, suite)
    }

    @Test func saveReplaceDeleteAndEndpointIsolation() async throws {
        let credentials = SettingsCredentials(); let (settings, defaults, suite) = settings(credentials)
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.endpointText = "https://one.example/v1/responses"; settings.modelText = "model-a"
        let saved = await settings.save(key: "key-one"); #expect(saved); #expect(settings.committedConfiguration?.model == "model-a")
        settings.modelText = "model-b"; let replaced = await settings.save(key: "key-two"); #expect(replaced)
        let replacedKey = try await credentials.read(for: URL(string: "https://one.example/v1/responses")!)
        #expect(replacedKey == "key-two")
        let deleted = await settings.deleteKey(); #expect(deleted)
        let secondKey = try await credentials.read(for: URL(string: "https://one.example/v1/responses")!)
        #expect(secondKey == nil)
        #expect(defaults.string(forKey: "agent.provider.model") == "model-b")
        #expect(defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "key-one" || ($0 as? String) == "key-two" } == false)
    }

    @Test func cancelResetsUncommittedDraft() async throws {
        let credentials = SettingsCredentials(); let (settings, defaults, suite) = settings(credentials)
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.endpointText = "https://saved.example/v1/responses"; settings.modelText = "saved"; let saved = await settings.save(key: "secret"); #expect(saved)
        settings.endpointText = "https://draft.example/v1/responses"; settings.modelText = "draft"; settings.resetDraft()
        #expect(settings.endpointText.contains("saved.example")); #expect(settings.modelText == "saved")
    }

    @Test func failedSavePreservesCommittedConfiguration() async throws {
        let credentials = SettingsCredentials(); let (settings, defaults, suite) = settings(credentials)
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.endpointText = "https://saved.example/v1/responses"; settings.modelText = "saved"; let saved = await settings.save(key: "secret"); #expect(saved)
        await credentials.setFailSave(true); settings.modelText = "new"; let replacement = await settings.save(key: "replacement"); #expect(!replacement); #expect(settings.committedConfiguration?.model == "saved")
        #expect(defaults.string(forKey: "agent.provider.model") == "saved")
    }

    @Test func twoEndpointsKeepSecretsIsolated() async throws {
        let credentials = SettingsCredentials(); let (settings, defaults, suite) = settings(credentials)
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.endpointText = "https://a.example/v1/responses"; settings.modelText = "a"; #expect(await settings.save(key: "key-a"))
        settings.endpointText = "https://b.example/v1/responses"; settings.modelText = "b"; #expect(await settings.save(key: "key-b"))
        #expect(try await credentials.read(for: URL(string: "https://a.example/v1/responses")!) == "key-a")
        #expect(try await credentials.read(for: URL(string: "https://b.example/v1/responses")!) == "key-b")
        #expect(await settings.deleteKey()); #expect(try await credentials.read(for: URL(string: "https://b.example/v1/responses")!) == nil); #expect(try await credentials.read(for: URL(string: "https://a.example/v1/responses")!) == "key-a")
    }

    @Test func unsavedDraftDoesNotChangeCommittedStatus() async throws {
        let credentials = SettingsCredentials(); let (settings, defaults, suite) = settings(credentials)
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.endpointText = "https://a.example/v1/responses"; settings.modelText = "a"; #expect(await settings.save(key: Optional<String>.none))
        try await credentials.save(apiKey: "key-a", for: URL(string: "https://a.example/v1/responses")!)
        settings.endpointText = "https://draft.example/v1/responses"; settings.modelText = "draft"; settings.refreshStatus(); try await Task.sleep(for: .milliseconds(20))
        #expect(settings.status == ProviderSettings.Status.configuredUnverified)
    }

    @Test func cliSaveDoesNotTouchKeychainAndPreservesAPIValues() async throws {
        let credentials = SettingsCredentials(); let (settings, defaults, suite) = settings(credentials)
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.endpointText = "https://api.example/v1/responses"; settings.modelText = "api-model"; #expect(await settings.save(key: "api-secret"))
        settings.selectBackend(.codexCLI); settings.cliPathText = "/opt/homebrew/bin/codex"; settings.modelText = "cli-model"; #expect(await settings.save(key: "must-not-store"))
        #expect(try await credentials.read(for: URL(string: "https://api.example/v1/responses")!) == "api-secret")
        let reloaded = ProviderSettings(credentials: credentials, defaults: defaults)
        #expect(reloaded.backend == .codexCLI); #expect(reloaded.modelText == "cli-model")
        reloaded.selectBackend(.responses); #expect(reloaded.modelText == "api-model"); #expect(reloaded.endpointText == "https://api.example/v1/responses")
    }

    @Test func resetDraftRestoresCommittedBackendAndMatchingModel() async throws {
        let credentials = SettingsCredentials(); let (settings, defaults, suite) = settings(credentials)
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.endpointText = "https://api.example/v1/responses"; settings.modelText = "api-model"; #expect(await settings.save(key: nil))
        settings.selectBackend(.codexCLI); settings.cliPathText = "/opt/homebrew/bin/codex"; settings.modelText = "cli-model"; #expect(await settings.save(key: nil))
        settings.selectBackend(.responses); settings.modelText = "draft"; settings.resetDraft()
        #expect(settings.backend == .codexCLI); #expect(settings.modelText == "cli-model"); #expect(!settings.isBusy)
    }

    @Test func cancellingPendingCLICheckClearsBusyAndIgnoresLateResult() async throws {
        let pending = PendingCLICheck(); let credentials = SettingsCredentials(); let (settings, defaults, suite) = settings(credentials)
        defer { defaults.removePersistentDomain(forName: suite) }
        let configured = ProviderSettings(credentials: credentials, defaults: defaults, cliChecker: { _ in await pending.wait() })
        configured.selectBackend(.codexCLI); configured.cliPathText = "/bin/echo"; #expect(await configured.save(key: nil))
        Task { await configured.checkCLILogin() }
        for _ in 0..<20 { if configured.isBusy { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(configured.isBusy); configured.resetDraft(); #expect(!configured.isBusy)
        await pending.resume((true, "late")); try await Task.sleep(for: .milliseconds(30))
        #expect(configured.status != .cliChecked); #expect(configured.cliVersion == nil)
    }
}

private extension SettingsCredentials {
    func setFailSave(_ value: Bool) { failSave = value }
}

private actor PendingCLICheck {
    var continuation: CheckedContinuation<(Bool, String?), Never>?
    var earlyResult: (Bool, String?)?
    func wait() async -> (Bool, String?) { if let earlyResult { self.earlyResult = nil; return earlyResult }; return await withCheckedContinuation { continuation = $0 } }
    func resume(_ value: (Bool, String?)) { if let continuation { continuation.resume(returning: value); self.continuation = nil } else { earlyResult = value } }
}
