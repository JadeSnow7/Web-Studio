import Foundation
import Testing
@testable import Web_Studio

@Suite(.serialized)
struct CredentialIntegrationTests {
    @Test func productionKeychainCrudUsesOnlyUniqueTestEndpoint() async throws {
        let endpoint = try #require(URL(string: "https://web-studio-test-\(UUID().uuidString).invalid/v1/responses"))
        let store = KeychainCredentialStore()
        do {
            try await store.save(apiKey: "web-studio-synthetic-token", for: endpoint)
            #expect(try await store.read(for: endpoint) == "web-studio-synthetic-token")
            try await store.save(apiKey: "web-studio-replacement-token", for: endpoint)
            #expect(try await store.read(for: endpoint) == "web-studio-replacement-token")
            try await store.delete(for: endpoint)
            #expect(try await store.read(for: endpoint) == nil)
        } catch {
            try? await store.delete(for: endpoint)
            throw error
        }
    }
}
