import Foundation
import Testing
@testable import Web_Studio

actor FakeCredentials: CredentialStore {
    var value: String?
    init(_ value: String? = nil) { self.value = value }
    func save(apiKey: String, for endpoint: URL) async throws { value = apiKey }
    func read(for endpoint: URL) async throws -> String? { value }
    func delete(for endpoint: URL) async throws { value = nil }
}

@Suite(.serialized)
struct AgentServiceTests {
    @Test func configurationRejectsUnsafeEndpoints() throws {
        #expect(throws: AgentServiceError.invalidConfiguration) { try ProviderConfiguration(endpoint: "http://example.com/v1/responses", model: "m") }
        #expect(throws: AgentServiceError.invalidConfiguration) { try ProviderConfiguration(endpoint: "https://u:p@example.com/v1/responses", model: "m") }
        #expect(throws: AgentServiceError.invalidConfiguration) { try ProviderConfiguration(endpoint: "https://example.com/v1/responses?q=x", model: "m") }
        #expect(throws: AgentServiceError.invalidConfiguration) { try ProviderConfiguration(model: " ") }
    }

    @Test func missingCredentialIsExplicit() async throws {
        let endpoint = try #require(URL(string: "https://example.com/v1/responses")); let config = try ProviderConfiguration(endpoint: endpoint.absoluteString, model: "m")
        let service = ConfiguredResponsesService(credentials: FakeCredentials(), provider: StubProvider())
        await #expect(throws: AgentServiceError.missingCredential) { try await service.answer(request: AgentRequest(question: "q", snapshots: [], configuration: config)) }
    }

    @Test func requestUsesInjectedCredentialAndProvider() async throws {
        let endpoint = try #require(URL(string: "https://example.com/v1/responses")); let config = try ProviderConfiguration(endpoint: endpoint.absoluteString, model: "m")
        let service = ConfiguredResponsesService(credentials: FakeCredentials("secret"), provider: StubProvider(answer: "grounded"))
        let answer = try await service.answer(request: AgentRequest(question: "q", snapshots: [], configuration: config)); #expect(answer == "grounded")
    }

    @Test func responseProviderParsesRealTransportPayload() async throws {
        let endpoint = try #require(URL(string: "https://example.com/v1/responses")); let config = try ProviderConfiguration(endpoint: endpoint.absoluteString, model: "m")
        let id = UUID(); let snapshot = ResourceSnapshot(resourceID: id, collectedAt: Date(timeIntervalSince1970: 1), text: "selected", isTruncated: false, errorMessage: nil, sourceURL: endpoint, title: "Source", range: 0..<8)
        ScriptedProtocol.configure(status: 200, body: Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"grounded answer"}]}]}"#.utf8))
        let session = URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [ScriptedProtocol.self]; return c }())
        let answer = try await URLSessionResponsesProvider(session: session).answer(request: AgentRequest(question: "q", snapshots: [snapshot], configuration: config), apiKey: "secret")
        #expect(answer == "grounded answer"); #expect(ScriptedProtocol.request()?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let bodyData = try #require(ScriptedProtocol.request().flatMap { request -> Data? in
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }; return data
        })
        let body = try #require(try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["store"] as? Bool == false); #expect(body["tools"] == nil); #expect(body["previous_response_id"] == nil)
        #expect((body["input"] as? String)?.contains(id.uuidString) == true); #expect((body["input"] as? String)?.contains("selected") == true)
    }

    @Test func responseProviderReportsHTTPMalformedAndRefusal() async throws {
        let endpoint = try #require(URL(string: "https://example.com/v1/responses")); let config = try ProviderConfiguration(endpoint: endpoint.absoluteString, model: "m"); let req = AgentRequest(question: "q", snapshots: [], configuration: config)
        let session = URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [ScriptedProtocol.self]; return c }()); let provider = URLSessionResponsesProvider(session: session)
        ScriptedProtocol.configure(status: 401, body: Data()); await #expect(throws: AgentServiceError.http(401)) { try await provider.answer(request: req, apiKey: "x") }
        ScriptedProtocol.configure(status: 429, body: Data()); await #expect(throws: AgentServiceError.http(429)) { try await provider.answer(request: req, apiKey: "x") }
        ScriptedProtocol.configure(status: 200, body: Data("no-json".utf8)); await #expect(throws: AgentServiceError.malformedResponse) { try await provider.answer(request: req, apiKey: "x") }
        ScriptedProtocol.configure(status: 200, body: Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"no"}]}]}"#.utf8)); await #expect(throws: AgentServiceError.refusal("no")) { try await provider.answer(request: req, apiKey: "x") }
    }

    @Test func responseProviderReportsEmptyIncompleteAndFailedResponses() async throws {
        let config = try ProviderConfiguration(endpoint: "https://example.com/v1/responses", model: "m")
        let req = AgentRequest(question: "q", snapshots: [], configuration: config)
        let session = URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [ScriptedProtocol.self]; return c }())
        let provider = URLSessionResponsesProvider(session: session)
        ScriptedProtocol.configure(status: 200, body: Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"  "}]}]}"#.utf8))
        await #expect(throws: AgentServiceError.emptyResponse) { try await provider.answer(request: req, apiKey: "key") }
        ScriptedProtocol.configure(status: 200, body: Data(#"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}"#.utf8))
        await #expect(throws: AgentServiceError.incomplete("max_output_tokens")) { try await provider.answer(request: req, apiKey: "key") }
        ScriptedProtocol.configure(status: 200, body: Data(#"{"status":"failed","error":{"message":"bad"}}"#.utf8))
        await #expect(throws: AgentServiceError.malformedResponse) { try await provider.answer(request: req, apiKey: "key") }
    }

    @Test func responseProviderRejectsInvalidCredentialBeforeTransport() async throws {
        let config = try ProviderConfiguration(endpoint: "https://example.com/v1/responses", model: "m")
        let req = AgentRequest(question: "q", snapshots: [], configuration: config)
        let provider = URLSessionResponsesProvider(session: URLSession(configuration: .ephemeral))
        await #expect(throws: AgentServiceError.invalidCredential) { try await provider.answer(request: req, apiKey: "bad key") }
    }

    @Test func responseProviderDeniesRedirects() async throws {
        let provider = URLSessionResponsesProvider(session: URLSession(configuration: .ephemeral))
        provider.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: URL(string: "https://example.com")!), willPerformHTTPRedirection: HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 302, httpVersion: nil, headerFields: nil)!, newRequest: URLRequest(url: URL(string: "https://other.example")!)) { request in
            #expect(request == nil)
        }
    }

    @Test func responseProviderCancellationStopsDelayedTransport() async throws {
        let config = try ProviderConfiguration(endpoint: "https://example.com/v1/responses", model: "m")
        let request = AgentRequest(question: "q", snapshots: [], configuration: config)
        DelayedProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedProtocol.self]
        let provider = URLSessionResponsesProvider(session: URLSession(configuration: configuration))
        let task = Task { try await provider.answer(request: request, apiKey: "key") }
        for _ in 0..<100 where !DelayedProtocol.isStarted() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(DelayedProtocol.isStarted())
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancellation unexpectedly succeeded") }
        catch { #expect(error as? AgentServiceError == .cancelled) }
        for _ in 0..<100 where !DelayedProtocol.isStopped() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(DelayedProtocol.isStopped())
    }

    @Test func keychainRejectsBlankAndControlCredentials() async throws {
        let store = KeychainCredentialStore()
        let endpoint = try #require(URL(string: "https://example.com/v1/responses"))
        await #expect(throws: AgentServiceError.invalidCredential) { try await store.save(apiKey: "  \n", for: endpoint) }
        await #expect(throws: AgentServiceError.invalidCredential) { try await store.save(apiKey: "key\u{0085}", for: endpoint) }
    }
}

private struct StubProvider: ResponsesProvider {
    var answer: String = ""
    func answer(request: AgentRequest, apiKey: String) async throws -> String { answer }
}

private final class ScriptedProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var status = 200; private static var body = Data(); private static var last: URLRequest?
    static func configure(status: Int, body: Data) { lock.lock(); defer { lock.unlock() }; self.status = status; self.body = body; last = nil }
    static func request() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return last }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.lock(); Self.last = request; let status = Self.status; let body = Self.body; Self.lock.unlock(); let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!; client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() {}
}

private final class DelayedProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var started = false
    private static var stopped = false
    static func reset() { lock.lock(); started = false; stopped = false; lock.unlock() }
    static func isStarted() -> Bool { lock.lock(); defer { lock.unlock() }; return started }
    static func isStopped() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.lock(); Self.started = true; Self.lock.unlock() }
    override func stopLoading() { Self.lock.lock(); Self.stopped = true; Self.lock.unlock() }
}
