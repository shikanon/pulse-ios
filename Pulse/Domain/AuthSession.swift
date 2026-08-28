import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import SwiftUI

struct PulseUser: Codable, Sendable, Equatable {
    let id: String
    let username: String
    let displayName: String
    let email: String?
    let role: String
    let termsAcceptance: PulseTermsAcceptance?

    init(id: String, username: String, displayName: String, email: String?, role: String, termsAcceptance: PulseTermsAcceptance? = nil) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.email = email
        self.role = role
        self.termsAcceptance = termsAcceptance
    }
}

struct PulseTermsAcceptance: Codable, Sendable, Equatable {
    let version: String
    let url: String
    let acceptedAt: Date

    func matches(_ policy: PulseTermsPolicy) -> Bool {
        version == policy.version && url == policy.url.absoluteString
    }
}

struct PulseSession: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let accessExpiresAt: Date
    let refreshExpiresAt: Date
}

struct PulseAuthentication: Decodable, Sendable {
    let user: PulseUser
    let session: PulseSession
    let created: Bool?
}

struct AppleDeletionAuthorization: Sendable, Equatable {
    let identityToken: String
    let nonce: String
    let authorizationCode: String
}

struct AccountDataExport: Codable, Sendable {
    let generatedAt: Date
    let user: PulseUser
    let works: [InteractiveApp]
    let comments: [AppComment]
    let assets: [GenerationAsset]
    let reports: [CommunityReport]
}

enum PulseCredentialStore {
    private static let service = "chat.lovetalk.pulse.session"
    private static let account = "active-user"

    static func load() -> PulseSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data
        else { return nil }
        return try? JSONDecoder.pulse.decode(PulseSession.self, from: data)
    }

    static func save(_ session: PulseSession) throws {
        let data = try JSONEncoder.pulse.encode(session)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PulseAPIError(message: "Secure session storage is unavailable.")
        }
        var create = query
        create[kSecValueData as String] = data
        create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(create as CFDictionary, nil) == errSecSuccess else {
            throw PulseAPIError(message: "Secure session storage is unavailable.")
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
@Observable
final class SessionModel {
    var user: PulseUser?
    var needsProfileSetup = false
    var needsTermsAcceptance = false
    var isSigningIn = false
    var authenticationError: String?

    let api: PulseAPIClient
    private var termsPolicy: PulseTermsPolicy?

    init(api: PulseAPIClient = PulseAPIClient()) {
        self.api = api
    }

    var isAuthenticated: Bool { user != nil }
    var allowsLocalDevelopment: Bool { api.isLocalDevelopmentServer }
    var canPerformMemberActions: Bool { isAuthenticated || allowsLocalDevelopment }
    /// A newly created account must finish its public profile before a deferred
    /// member action is resumed. This keeps the original intent without
    /// presenting a composer or destructive confirmation behind profile setup.
    var canResumeMemberActions: Bool { canPerformMemberActions && !needsProfileSetup && !needsTermsAcceptance }
    var currentTermsPolicy: PulseTermsPolicy? { termsPolicy }

    func configureTermsAcceptance(_ policy: PulseTermsPolicy?) {
        termsPolicy = policy
        updateTermsRequirement()
    }

    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>, nonce: String) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            guard case let .success(authorization) = result,
                  let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityTokenData = credential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8)
            else {
                throw PulseAPIError(message: "Apple could not provide a usable identity token.")
            }
            let displayName = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            let authentication = try await api.signInWithApple(
                identityToken: identityToken,
                nonce: nonce,
                displayName: displayName.isEmpty ? nil : displayName
            )
            user = authentication.user
            needsProfileSetup = authentication.created == true
            updateTermsRequirement()
            authenticationError = nil
        } catch {
            authenticationError = error.localizedDescription
        }
    }

    func restore() async {
        guard PulseCredentialStore.load() != nil else { return }
        do {
            user = try await api.currentUser()
            updateTermsRequirement()
            authenticationError = nil
        } catch {
            PulseCredentialStore.clear()
            user = nil
        }
    }

    func signOut() async {
        if let ownerID = user?.id {
            for upload in BackgroundAssetUploadStore.records(ownerID: ownerID) {
                BackgroundAssetUploadCoordinator.shared.cancelAndDiscard(assetID: upload.assetID)
                try? await api.cancelAssetUpload(id: upload.assetID)
            }
        }
        do { try await api.signOut() } catch { }
        PulseCredentialStore.clear()
        user = nil
        needsProfileSetup = false
        needsTermsAcceptance = false
    }

    func completeAccountDeletion() {
        if let ownerID = user?.id {
            for upload in BackgroundAssetUploadStore.records(ownerID: ownerID) {
                BackgroundAssetUploadCoordinator.shared.cancelAndDiscard(assetID: upload.assetID)
            }
        }
        PulseCredentialStore.clear()
        ComposerDraftStore.clearAll()
        PendingAssetSafetyRetryStore.clearAll()
        BackgroundAssetUploadStore.discardAll()
        user = nil
        needsProfileSetup = false
        needsTermsAcceptance = false
        authenticationError = nil
    }

    func updateProfile(username: String, displayName: String) async throws {
        let updated = try await api.updateProfile(username: username, displayName: displayName)
        user = updated
        needsProfileSetup = false
    }

    func acceptTerms() async throws {
        user = try await api.acceptTerms()
        updateTermsRequirement()
    }

    private func updateTermsRequirement() {
        guard let policy = termsPolicy, let user else {
            needsTermsAcceptance = false
            return
        }
        needsTermsAcceptance = user.termsAcceptance?.matches(policy) != true
    }

    func clearError() { authenticationError = nil }
}

struct AppleSignInButton: View {
    @Environment(SessionModel.self) private var session
    @State private var nonce = ""

    var body: some View {
        SignInWithAppleButton(.continue) { request in
            let rawNonce = makeNonce()
            nonce = SHA256.hash(data: Data(rawNonce.utf8)).map { String(format: "%02x", $0) }.joined()
            request.nonce = nonce
            request.requestedScopes = [.fullName, .email]
        } onCompletion: { result in
            Task { await session.completeAppleSignIn(result, nonce: nonce) }
        }
        .signInWithAppleButtonStyle(.white)
        .frame(height: 50)
        .disabled(session.isSigningIn)
        .accessibilityLabel("Continue with Apple")
    }

    private func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64EncodedString()
    }
}

private extension JSONDecoder {
    static var pulse: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let string = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid RFC 3339 timestamp")
        }
        return decoder
    }
}

private extension JSONEncoder {
    static var pulse: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
