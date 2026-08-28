import Foundation

struct PulseClientConfiguration: Codable, Equatable, Sendable {
    let maintenance: Bool
    let maintenanceMessage: String?
    let minimumIOSVersion: String?
    let minimumIOSBuild: Int?
    let supportURL: String?
    let privacyPolicyURL: String?
    let termsURL: String?
    let termsVersion: String?
    let appStoreURL: String?

    init(
        maintenance: Bool,
        maintenanceMessage: String?,
        minimumIOSVersion: String?,
        minimumIOSBuild: Int?,
        supportURL: String?,
        privacyPolicyURL: String?,
        appStoreURL: String?,
        termsURL: String? = nil,
        termsVersion: String? = nil
    ) {
        self.maintenance = maintenance
        self.maintenanceMessage = maintenanceMessage
        self.minimumIOSVersion = minimumIOSVersion
        self.minimumIOSBuild = minimumIOSBuild
        self.supportURL = supportURL
        self.privacyPolicyURL = privacyPolicyURL
        self.appStoreURL = appStoreURL
        self.termsURL = termsURL
        self.termsVersion = termsVersion
    }

    func requiresUpdate(for version: PulseAppVersion) -> Bool {
        if let minimumIOSVersion, PulseAppVersion.compare(version.marketingVersion, minimumIOSVersion) == .orderedAscending {
            return true
        }
        if let minimumIOSBuild, minimumIOSBuild > version.buildNumber {
            return true
        }
        return false
    }

    var resolvedSupportURL: URL? { safeHTTPSURL(supportURL) }
    var resolvedPrivacyPolicyURL: URL? { safeHTTPSURL(privacyPolicyURL) }
    var resolvedAppStoreURL: URL? { safeHTTPSURL(appStoreURL, allowedHosts: ["apps.apple.com", "itunes.apple.com"]) }
    var termsPolicy: PulseTermsPolicy? {
        guard let url = safeHTTPSURL(termsURL),
              let version = normalizedTermsVersion(termsVersion)
        else { return nil }
        return PulseTermsPolicy(url: url, version: version)
    }

    private func safeHTTPSURL(_ rawValue: String?, allowedHosts: Set<String>? = nil) -> URL? {
        guard let rawValue,
              let url = URL(string: rawValue),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              allowedHosts?.contains(host) ?? true
        else { return nil }
        return url
    }

    private func normalizedTermsVersion(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= 128,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }
}

/// The policy is obtained from the public launch configuration, while the
/// confirmed receipt is always issued by the API. It never includes a device
/// identifier or user-created value.
struct PulseTermsPolicy: Equatable, Sendable {
    let url: URL
    let version: String
}

struct PulseAppVersion: Equatable, Sendable {
    let marketingVersion: String
    let buildNumber: Int

    init(marketingVersion: String, buildNumber: Int) {
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
    }

    /// A user-facing value for Settings and support conversations. Keep the
    /// marketing version and build together: either number on its own is not
    /// sufficient to identify the binary a person is running.
    var displayLabel: String {
        "Version \(marketingVersion) (\(buildNumber))"
    }

    static var current: PulseAppVersion {
        let values = Bundle.main.infoDictionary
        return PulseAppVersion(
            marketingVersion: values?["CFBundleShortVersionString"] as? String ?? "0",
            buildNumber: Int(values?["CFBundleVersion"] as? String ?? "0") ?? 0
        )
    }

    static func compare(_ current: String, _ minimum: String) -> ComparisonResult? {
        func components(for value: String) -> [Int]? {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 3 else { return nil }
            let values = parts.compactMap { Int($0) }
            guard values.count == parts.count, values.allSatisfy({ $0 >= 0 }) else { return nil }
            return values + Array(repeating: 0, count: 3 - values.count)
        }
        guard let currentParts = components(for: current), let minimumParts = components(for: minimum) else { return nil }
        for index in currentParts.indices where currentParts[index] != minimumParts[index] {
            return currentParts[index] < minimumParts[index] ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
}

/// The declaration is attached to every request made to the Pulse API,
/// including the custom-scheme proxy used by WKWebView. It is not a device
/// identifier and never participates in authentication; it lets the service
/// remove or reject a work whose interactive runtime needs a newer binary.
enum PulseClientRuntimeDeclaration {
    static func apply(to request: inout URLRequest) {
        let version = PulseAppVersion.current
        request.setValue("ios", forHTTPHeaderField: "X-Pulse-Client-Platform")
        request.setValue(version.marketingVersion, forHTTPHeaderField: "X-Pulse-Client-Version")
        request.setValue(String(version.buildNumber), forHTTPHeaderField: "X-Pulse-Client-Build")
    }
}

enum PulseLaunchState: Equatable {
    case loading
    case ready
    case maintenance(PulseClientConfiguration)
    case updateRequired(PulseClientConfiguration)
    case unavailable(String)

    var allowsAppContent: Bool {
        if case .ready = self { return true }
        return false
    }
}

struct ClientConfigurationEnvelope: Decodable {
    let configuration: PulseClientConfiguration
}

/// A brief, origin-bound copy of the last verified launch policy. It is only
/// used to make a recent public Feed cache readable while the app is offline;
/// it never turns a failed launch into permission to create, publish, or make
/// other member changes.
struct ClientConfigurationSnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let origin: String
    let savedAt: Date
    let configuration: PulseClientConfiguration
}

struct ClientConfigurationCacheStore: Sendable {
    /// Launch policy can change quickly for safety incidents. Keep this much
    /// shorter than the Feed's read-only cache window.
    static let maximumAge: TimeInterval = 5 * 60

    let fileURL: URL
    private let origin: String

    init(apiOrigin: URL? = nil, fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.origin = apiOrigin?.absoluteString ?? "default"
    }

    func load(now: Date = .now, maximumAge: TimeInterval = Self.maximumAge) -> ClientConfigurationSnapshot? {
        guard maximumAge > 0,
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? Self.decoder.decode(ClientConfigurationSnapshot.self, from: data),
              snapshot.schemaVersion == ClientConfigurationSnapshot.schemaVersion,
              snapshot.origin == origin
        else {
            remove()
            return nil
        }

        let age = now.timeIntervalSince(snapshot.savedAt)
        guard age >= -60, age <= maximumAge else {
            remove()
            return nil
        }
        return snapshot
    }

    func save(_ configuration: PulseClientConfiguration, savedAt: Date = .now) {
        let snapshot = ClientConfigurationSnapshot(
            schemaVersion: ClientConfigurationSnapshot.schemaVersion,
            origin: origin,
            savedAt: savedAt,
            configuration: configuration
        )
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.encoder.encode(snapshot).write(to: fileURL, options: [.atomic])
        } catch {
            // The network launch path remains authoritative; this cache is
            // best-effort and must not surface file-system details to users.
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static var defaultFileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appending(path: "Pulse", directoryHint: .isDirectory)
            .appending(path: "client-configuration-v1.json", directoryHint: .notDirectory)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
