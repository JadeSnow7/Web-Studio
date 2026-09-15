import Combine
import Foundation

/// Stores provider preferences separately from the secret. The API key is only ever
/// accepted as write-only input and is never published or persisted in UserDefaults.
@MainActor
final class ProviderSettings: ObservableObject {
    enum Status: Equatable {
        case notConfigured
        case configuredUnverified
        case missingKey
        case cliConfiguredUnverified
        case cliChecked
        case cliUnavailable
        case error
    }

    @Published var endpointText: String
    @Published var modelText: String
    @Published var backend: AgentBackend
    @Published var cliPathText: String
    @Published private(set) var status: Status = .notConfigured
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false
    @Published private(set) var cliVersion: String?
    private var apiModelDraft = ""
    private var cliModelDraft = ""
    private var checkTask: Task<Void, Never>?
    private var checkGeneration = 0
    private let cliChecker: @Sendable (String) async -> (Bool, String?)

    private let credentials: any CredentialStore
    private let defaults: UserDefaults
    private let endpointKey = "agent.provider.endpoint"
    private let modelKey = "agent.provider.model"
    private let backendKey = "agent.provider.backend"
    private let cliPathKey = "agent.provider.cliPath"
    private let cliModelKey = "agent.provider.cliModel"
    private var statusTask: Task<Void, Never>?
    private var statusGeneration = 0
    private(set) var committedConfiguration: ProviderConfiguration?
    var onConfigurationChanged: ((ProviderConfiguration?) -> Void)?

    init(credentials: (any CredentialStore)? = nil, defaults: UserDefaults = .standard, cliChecker: (@Sendable (String) async -> (Bool, String?))? = nil) {
        self.credentials = credentials ?? KeychainCredentialStore()
        self.defaults = defaults
        self.cliChecker = cliChecker ?? { path in
            let runner = CodexProcessRunner()
            do { let version = try await runner.run(executable: URL(fileURLWithPath: path), arguments: ["--version"], timeout: .seconds(10), maxOutputBytes: 16 * 1024); let login = try await runner.run(executable: URL(fileURLWithPath: path), arguments: ["login", "status"], timeout: .seconds(10), maxOutputBytes: 16 * 1024); return (version.exitCode == 0 && login.exitCode == 0, String(data: version.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)) } catch { return (false, nil) }
        }
        endpointText = defaults.string(forKey: endpointKey) ?? "https://api.openai.com/v1/responses"
        let storedBackend = AgentBackend(rawValue: defaults.string(forKey: backendKey) ?? "responses") ?? .responses
        backend = storedBackend
        apiModelDraft = defaults.string(forKey: modelKey) ?? ""
        cliModelDraft = defaults.string(forKey: cliModelKey) ?? ""
        modelText = storedBackend == .codexCLI ? cliModelDraft : apiModelDraft
        cliPathText = defaults.string(forKey: cliPathKey) ?? "/opt/homebrew/bin/codex"
        committedConfiguration = storedBackend == .codexCLI ? try? ProviderConfiguration(codexCLIPath: cliPathText, model: cliModelDraft) : try? ProviderConfiguration(endpoint: endpointText, model: apiModelDraft)
    }

    var configuration: ProviderConfiguration? {
        backend == .codexCLI ? try? ProviderConfiguration(codexCLIPath: cliPathText, model: modelText) : try? ProviderConfiguration(endpoint: endpointText, model: modelText)
    }

    @discardableResult
    func loadPersisted() -> ProviderConfiguration? {
        let value = configuration
        committedConfiguration = value
        onConfigurationChanged?(value)
        refreshStatus()
        return value
    }

    func refreshStatus() {
        statusTask?.cancel()
        statusGeneration += 1
        guard let configuration = committedConfiguration else {
            status = .notConfigured
            errorMessage = nil
            return
        }
        let generation = statusGeneration
        if backend == .codexCLI { status = .cliConfiguredUnverified; errorMessage = nil; return }
        statusTask = Task { [credentials] in
            do {
                guard let endpoint = configuration.endpoint else { return }
                let key = try await credentials.read(for: endpoint)
                guard !Task.isCancelled, generation == self.statusGeneration else { return }
                status = (key?.isEmpty == false) ? .configuredUnverified : .missingKey
                errorMessage = nil
            } catch {
                guard !Task.isCancelled, generation == self.statusGeneration else { return }
                status = .error
                errorMessage = "Unable to check the system credential store."
            }
        }
    }

    @discardableResult func save(key: String?) async -> Bool {
        guard let configuration else {
            status = .notConfigured
            errorMessage = "Enter a valid HTTPS endpoint and model."
            return false
        }
        isBusy = true; defer { isBusy = false }
        do {
            if backend == .responses { apiModelDraft = configuration.model } else { cliModelDraft = configuration.model }
            if backend == .responses, let key, !key.isEmpty {
                guard let endpoint = configuration.endpoint else { throw AgentServiceError.invalidConfiguration }
                try await credentials.save(apiKey: key, for: endpoint)
            }
            if backend == .responses, let endpoint = configuration.endpoint { defaults.set(endpoint.absoluteString, forKey: endpointKey) }
            defaults.set(configuration.model, forKey: backend == .codexCLI ? cliModelKey : modelKey)
            defaults.set(backend.rawValue, forKey: backendKey)
            defaults.set(cliPathText, forKey: cliPathKey)
            committedConfiguration = configuration
            errorMessage = nil
            onConfigurationChanged?(configuration)
            refreshStatus()
            return true
        } catch {
            status = .error
            errorMessage = "Could not save provider settings or credential."
            return false
        }
    }

    @discardableResult func deleteKey() async -> Bool {
        guard backend == .responses else { status = .cliConfiguredUnverified; return true }
        statusTask?.cancel(); statusGeneration += 1
        guard let endpoint = try? ProviderConfiguration(endpoint: endpointText, model: modelText.isEmpty ? "placeholder" : modelText).endpoint else {
            status = .notConfigured
            errorMessage = "Enter a valid endpoint before deleting its key."
            return false
        }
        isBusy = true; defer { isBusy = false }
        do {
            try await credentials.delete(for: endpoint)
            status = .missingKey
            errorMessage = nil
            return true
        } catch {
            status = .error
            errorMessage = "Could not delete the provider credential."
            return false
        }
    }
    func resetDraft() {
        checkTask?.cancel(); checkTask = nil; checkGeneration += 1; isBusy = false; cliVersion = nil
        backend = committedConfiguration?.backend ?? .responses
        endpointText = defaults.string(forKey: endpointKey) ?? "https://api.openai.com/v1/responses"
        apiModelDraft = defaults.string(forKey: modelKey) ?? ""
        cliModelDraft = defaults.string(forKey: cliModelKey) ?? ""
        modelText = backend == .codexCLI ? cliModelDraft : apiModelDraft
        cliPathText = committedConfiguration?.cliPath ?? "/opt/homebrew/bin/codex"
        errorMessage = nil
        refreshStatus()
    }

    func selectBackend(_ value: AgentBackend) {
        guard backend != value, !isBusy else { return }
        if backend == .responses { apiModelDraft = modelText } else { cliModelDraft = modelText }
        backend = value
        modelText = value == .responses ? apiModelDraft : cliModelDraft
        checkTask?.cancel(); checkGeneration += 1; cliVersion = nil
        refreshStatus()
    }

    func invalidateCheck() { checkTask?.cancel(); checkTask = nil; checkGeneration += 1; cliVersion = nil; if backend == .codexCLI { status = .cliConfiguredUnverified; isBusy = false } }

    func checkCLILogin() async {
        guard !isBusy else { return }
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil else { status = .cliUnavailable; errorMessage = "Codex CLI check requires the local validation build (App Sandbox cannot launch the host CLI)."; return }
        guard backend == .codexCLI, let path = configuration?.cliPath, FileManager.default.isExecutableFile(atPath: path) else { status = .cliUnavailable; return }
        checkGeneration += 1; let generation = checkGeneration; isBusy = true
        checkTask?.cancel(); let checker = cliChecker; checkTask = Task { [weak self] in
            let result = await checker(path)
            await MainActor.run { guard let self, self.checkGeneration == generation, self.backend == .codexCLI else { return }; self.cliVersion = result.1; self.status = result.0 ? .cliChecked : .cliUnavailable; self.isBusy = false }
        }
    }
}
