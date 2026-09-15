import Foundation
import Testing
@testable import Web_Studio

@Suite(.serialized)
struct CodexBackendTests {
    @Test func parsesCompletedAgentTranscript() throws {
        let data = Data(#"""
        {"type":"item.completed","item":{"type":"agent_message","text":"连接成功。"}}
        {"type":"turn.completed"}
        """#.utf8)
        #expect(try CodexCLIProvider.parseJSONL(data) == "连接成功。")
    }

    @Test func parsesDataArrivingInPartialUTF8Chunks() throws {
        let whole = Data(#"""
        {"type":"item.completed","item":{"type":"agent_message","text":"你好"}}
        {"type":"turn.completed"}
        """#.utf8)
        let split = whole.index(whole.startIndex, offsetBy: 64)
        var received = Data(whole[..<split]); received.append(whole[split...])
        #expect(try CodexCLIProvider.parseJSONL(received) == "你好")
    }

    @Test func rejectsMalformedOrIncompleteTranscripts() {
        #expect(throws: AgentServiceError.cliInvalidOutput) { try CodexCLIProvider.parseJSONL(Data("not-json".utf8)) }
        #expect(throws: AgentServiceError.cliInvalidOutput) { try CodexCLIProvider.parseJSONL(Data([0xff, 0xfe])) }
        #expect(throws: AgentServiceError.cliInvalidOutput) { try CodexCLIProvider.parseJSONL(Data(#"{"type":"item.completed","item":{"type":"agent_message","text":"answer"}}"#.utf8)) }
        #expect(throws: AgentServiceError.cliFailure("request failed")) { try CodexCLIProvider.parseJSONL(Data(#"{"type":"turn.failed"}"#.utf8)) }
        #expect(throws: AgentServiceError.cliObservedTool) { try CodexCLIProvider.parseJSONL(Data(#"""
        {"type":"item.completed","item":{"type":"command_execution","command":"pwd"}}
        {"type":"turn.completed"}
        """#.utf8)) }
        #expect(throws: AgentServiceError.cliInvalidOutput) { try CodexCLIProvider.parseJSONL(Data(#"""
        {"type":"item.completed","item":{"type":"agent_message","text":" "}}
        {"type":"turn.completed"}
        """#.utf8)) }
    }

    @Test func requiresCompletedAgentMessageBeforeTurnCompletion() {
        #expect(throws: AgentServiceError.cliInvalidOutput) {
            try CodexCLIProvider.parseJSONL(Data(#"""
            {"type":"item.started","item":{"type":"agent_message","text":"draft"}}
            {"type":"turn.completed"}
            """#.utf8))
        }
    }

    @Test func rejectsAnswerArrivingAfterCompletion() {
        #expect(throws: AgentServiceError.cliInvalidOutput) {
            try CodexCLIProvider.parseJSONL(Data(#"""
            {"type":"turn.completed"}
            {"type":"item.completed","item":{"type":"agent_message","text":"late"}}
            """#.utf8))
        }
    }

    @Test func combinesMultipleCompletedAgentMessagesInOrder() throws {
        let data = Data(#"""
        {"type":"item.completed","item":{"type":"agent_message","text":"first"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"second"}}
        {"type":"turn.completed"}
        """#.utf8)
        #expect(try CodexCLIProvider.parseJSONL(data) == "first\nsecond")
    }

    @Test func codexBackendDoesNotReadResponsesKeychain() async throws {
        let configuration = try ProviderConfiguration(codexCLIPath: "/bin/false")
        let fake = StubCodexProvider(answer: "backend answer")
        let service = ConfiguredAgentService(credentials: ExplodingCredentials(), codex: fake)
        let answer = try await service.answer(request: AgentRequest(question: "q", snapshots: [], configuration: configuration))
        #expect(answer == "backend answer")
        #expect(await fake.calls == 1)
    }
}

private actor ExplodingCredentials: CredentialStore {
    func save(apiKey: String, for endpoint: URL) async throws { Issue.record("Codex backend unexpectedly saved credentials") }
    func read(for endpoint: URL) async throws -> String? { Issue.record("Codex backend unexpectedly read credentials"); return nil }
    func delete(for endpoint: URL) async throws { Issue.record("Codex backend unexpectedly deleted credentials") }
}

private actor StubCodexProvider: AgentBackendProvider {
    let answerText: String
    var calls = 0
    init(answer: String) { answerText = answer }
    func answer(request: AgentRequest) async throws -> String { calls += 1; return answerText }
}
