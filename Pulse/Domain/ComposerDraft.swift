import Foundation
import Security
import CryptoKit

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
    var creationContext: CreationContext? = nil

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
        #if DEBUG && targetEnvironment(simulator)
        return SimulatorComposerDraftFiles.load(ownerID: ownerID, parentWorkID: parentWorkID)
        #else
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
        #endif
    }

    static func save(_ draft: ComposerDraft) throws {
        #if DEBUG && targetEnvironment(simulator)
        try SimulatorComposerDraftFiles.save(draft)
        return
        #endif
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
        #if DEBUG && targetEnvironment(simulator)
        SimulatorComposerDraftFiles.clear(ownerID: ownerID, parentWorkID: parentWorkID)
        #endif
        let account = ComposerDraft.storageAccount(ownerID: ownerID, parentWorkID: parentWorkID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func clearAll() {
        #if DEBUG && targetEnvironment(simulator)
        SimulatorComposerDraftFiles.clearAll()
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}

#if DEBUG && targetEnvironment(simulator)
private enum SimulatorComposerDraftFiles {
    static func directory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appending(path: "SimulatorComposerDrafts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var url = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return root
    }
    static func file(ownerID: String, parentWorkID: UUID?) throws -> URL {
        let account = ComposerDraft.storageAccount(ownerID: ownerID, parentWorkID: parentWorkID)
        let name = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        return try directory().appending(path: name + ".json")
    }
    static func load(ownerID: String, parentWorkID: UUID?) -> ComposerDraft? {
        guard let url = try? file(ownerID: ownerID, parentWorkID: parentWorkID), let data = try? Data(contentsOf: url), let draft = try? JSONDecoder().decode(ComposerDraft.self, from: data), draft.ownerID == ownerID, draft.parentWorkID == parentWorkID else { return nil }
        return draft
    }
    static func save(_ draft: ComposerDraft) throws {
        let url = try file(ownerID: draft.ownerID, parentWorkID: draft.parentWorkID)
        try JSONEncoder().encode(draft).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func clear(ownerID: String, parentWorkID: UUID?) { if let url = try? file(ownerID: ownerID, parentWorkID: parentWorkID) { try? FileManager.default.removeItem(at: url) } }
    static func clearAll() { if let url = try? directory() { try? FileManager.default.removeItem(at: url) } }
}
#endif
