import Foundation
import Security

enum RealtimeCredentialError: Error, Equatable, Sendable {
    case invalidReference
    case emptySecret
    case unavailable
}

protocol RealtimeCredentialBackend: Sendable {
    func put(reference: String, secret: String) async throws
    func get(reference: String) async throws -> String?
    func remove(reference: String) async throws
}

struct RealtimeCredentialStore: Sendable {
    let backend: any RealtimeCredentialBackend

    init(backend: any RealtimeCredentialBackend = KeychainRealtimeCredentialBackend()) {
        self.backend = backend
    }

    func save(reference: String, secret: String) async throws {
        try validate(reference)
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RealtimeCredentialError.emptySecret
        }
        try await backend.put(reference: reference, secret: secret)
    }

    func load(reference: String) async throws -> String? {
        try validate(reference)
        return try await backend.get(reference: reference)
    }

    func delete(reference: String) async throws {
        try validate(reference)
        try await backend.remove(reference: reference)
    }

    private func validate(_ reference: String) throws {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
        )
        guard !reference.isEmpty,
              reference.utf8.count <= 128,
              reference.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw RealtimeCredentialError.invalidReference
        }
    }
}

actor KeychainRealtimeCredentialBackend: RealtimeCredentialBackend {
    private let service = "com.franklioxygen.v2s.native-realtime"

    func put(reference: String, secret: String) throws {
        let query = baseQuery(reference)
        let value = Data(secret.utf8)
        let update: [String: Any] = [kSecValueData as String: value]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw RealtimeCredentialError.unavailable
        }

        var add = query
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem,
           SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess {
            return
        }
        throw RealtimeCredentialError.unavailable
    }

    func get(reference: String) throws -> String? {
        var query = baseQuery(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw RealtimeCredentialError.unavailable
        }
        return secret
    }

    func remove(reference: String) throws {
        let status = SecItemDelete(baseQuery(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RealtimeCredentialError.unavailable
        }
    }

    private func baseQuery(_ reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
    }
}
