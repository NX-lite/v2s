import Foundation
import Testing
@testable import v2s

private actor MemoryCredentialBackend: RealtimeCredentialBackend {
    private var secrets: [String: String] = [:]

    func put(reference: String, secret: String) async throws {
        secrets[reference] = secret
    }

    func get(reference: String) async throws -> String? {
        secrets[reference]
    }

    func remove(reference: String) async throws {
        secrets.removeValue(forKey: reference)
    }
}

@Suite struct RealtimeCredentialStoreTests {
    @Test func roundTripAndDeleteWithoutSettingsSecret() async throws {
        let store = RealtimeCredentialStore(backend: MemoryCredentialBackend())
        try await store.save(reference: "native-key-1", secret: "test-secret-value")
        #expect(try await store.load(reference: "native-key-1") == "test-secret-value")
        try await store.delete(reference: "native-key-1")
        #expect(try await store.load(reference: "native-key-1") == nil)

        let json = try JSONEncoder().encode(AppSettings.default)
        #expect(!String(decoding: json, as: UTF8.self).contains("test-secret-value"))
    }

    @Test func emptySecretAndUnsafeReferenceFailBeforeBackendCall() async throws {
        let store = RealtimeCredentialStore(backend: MemoryCredentialBackend())

        for secret in ["", "  "] {
            do {
                try await store.save(reference: "native-key-1", secret: secret)
                Issue.record("empty secret was accepted")
            } catch let error as RealtimeCredentialError {
                #expect(error == .emptySecret)
            }
        }

        do {
            try await store.save(reference: "../unsafe", secret: "value")
            Issue.record("unsafe reference was accepted")
        } catch let error as RealtimeCredentialError {
            #expect(error == .invalidReference)
        }
    }
}
