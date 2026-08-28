import Foundation
import Security

/// A device-local recovery record. It deliberately stores only server asset IDs,
/// never private asset bytes, object keys, session tokens, or generated source.
struct ComposerDraft: Codable, Equatable, Sendable {
    let ownerID: String
    let parentWorkID: UUID?
    var instruction: String
    var assetIDs: [UUID]
    var workID: UUID?
    var generationID: UUID?
    let workIdempotencyKey: String
    let generationIdempotencyKey: String
    let createdAt: Date
    var updatedAt: Date

    static func fresh(ownerID: String, parentWorkID: UUID?, instruction: String, assetIDs: [UUID]) -> ComposerDraft {
        let now = Date()
        return ComposerDraft(
            ownerID: ownerID,
            parentWorkID: parentWorkID,
            instruction: instruction,
            assetIDs: assetIDs,
            workID: nil,
            generationID: nil,
            workIdempotencyKey: UUID().uuidString,
            generationIdempotencyKey: UUID().uuidString,
            createdAt: now,
            updatedAt: now
        )
    }

    var storageAccount: String {
        Self.storageAccount(ownerID: ownerID, parentWorkID: parentWorkID)
    }

    static func storageAccount(ownerID: String, parentWorkID: UUID?) -> String {
        "\(ownerID):\(parentWorkID?.uuidString.lowercased() ?? "original")"
    }
}

enum ComposerDraftStore {
    private static let service = "chat.lovetalk.pulse.composer-draft"

    static func load(ownerID: String, parentWorkID: UUID?) -> ComposerDraft? {
        let account = ComposerDraft.storageAccount(ownerID: ownerID, parentWorkID: parentWorkID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data,
              let draft = try? JSONDecoder().decode(ComposerDraft.self, from: data),
              draft.ownerID == ownerID,
              draft.parentWorkID == parentWorkID
        else { return nil }
        return draft
    }

    static func save(_ draft: ComposerDraft) throws {
        let data = try JSONEncoder().encode(draft)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: draft.storageAccount
        ]
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PulseAPIError(message: "Secure draft storage is unavailable.")
        }
        var create = query
        create[kSecValueData as String] = data
        create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(create as CFDictionary, nil) == errSecSuccess else {
            throw PulseAPIError(message: "Secure draft storage is unavailable.")
        }
    }

    static func clear(ownerID: String, parentWorkID: UUID?) {
        let account = ComposerDraft.storageAccount(ownerID: ownerID, parentWorkID: parentWorkID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func clearAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}
