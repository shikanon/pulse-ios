import Foundation

enum PulseDeepLink: Equatable {
    case remix(UUID)
    case publicWork(slug: String)
    case report(slug: String)

    static func parse(_ url: URL, universalLinkHost: String? = PulseEndpointConfiguration.bundledUniversalLinkHost) -> PulseDeepLink? {
        let components = url.pathComponents.filter { $0 != "/" }
        let identifier: String?
        switch url.scheme?.lowercased() {
        case "pulse":
            guard let host = url.host?.lowercased(), components.count == 1 else { return nil }
            switch host {
            case "remix":
                identifier = components[0]
            case "report":
                guard isValidPublicSlug(components[0]) else { return nil }
                return .report(slug: components[0].lowercased())
            default:
                return nil
            }
        case "https":
            guard let universalLinkHost = PulseEndpointConfiguration.approvedUniversalLinkHost(universalLinkHost),
                  url.host?.lowercased() == universalLinkHost,
                  components.count == 2
            else { return nil }
            switch components[0].lowercased() {
            case "remix":
                identifier = components[1]
            case "a":
                guard isValidPublicSlug(components[1]) else { return nil }
                return .publicWork(slug: components[1].lowercased())
            default:
                return nil
            }
        default:
            return nil
        }
        guard let identifier, let workID = UUID(uuidString: identifier) else { return nil }
        return .remix(workID)
    }

    private static func isValidPublicSlug(_ slug: String) -> Bool {
        guard (1...64).contains(slug.utf8.count) else { return false }
        return slug.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 70) || (scalar.value >= 97 && scalar.value <= 102)
        }
    }
}
