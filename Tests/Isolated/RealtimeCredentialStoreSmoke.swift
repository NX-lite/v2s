import Foundation

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

@main struct RealtimeCredentialStoreSmoke {
    static func main() async throws {
        let store = RealtimeCredentialStore(backend: MemoryCredentialBackend())
        try await store.save(reference: "native-key-1", secret: "test-secret-value")
        let loaded = try await store.load(reference: "native-key-1")
        precondition(loaded == "test-secret-value")
        try await store.delete(reference: "native-key-1")
        let afterDelete = try await store.load(reference: "native-key-1")
        precondition(afterDelete == nil)

        do {
            try await store.save(reference: "native-key-1", secret: " ")
            preconditionFailure("blank secret was accepted")
        } catch RealtimeCredentialError.emptySecret {
        }

        do {
            try await store.save(reference: "../unsafe", secret: "value")
            preconditionFailure("unsafe reference was accepted")
        } catch RealtimeCredentialError.invalidReference {
        }
    }
}
