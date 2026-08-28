import Foundation

enum PulseEndpointConfiguration {
    static let unavailableBaseURL = URL(string: "https://configuration.invalid/v1")!

    static var bundledAPIBaseURL: String? {
        Bundle.main.object(forInfoDictionaryKey: "PulseAPIBaseURL") as? String
    }

    static var bundledUniversalLinkHost: String? {
        approvedUniversalLinkHost(Bundle.main.object(forInfoDictionaryKey: "PulseUniversalLinkHost") as? String)
    }

    static func approvedAPIBaseURL(_ value: String?, allowsLocalDevelopment: Bool) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: value),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path == "/v1",
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased()
        else { return nil }

        if scheme == "https", isDeployableHost(host) {
            return url
        }
        if allowsLocalDevelopment, scheme == "http", isLocalHost(host) {
            return url
        }
        return nil
    }

    static func approvedUniversalLinkHost(_ value: String?) -> String? {
        guard let host = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty,
              !host.contains("/"),
              !host.contains(":"),
              isDeployableHost(host)
        else { return nil }
        return host
    }

    private static func isDeployableHost(_ host: String) -> Bool {
        !isLocalHost(host) && !host.hasSuffix(".invalid") && !host.hasSuffix(".example")
    }

    private static func isLocalHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
