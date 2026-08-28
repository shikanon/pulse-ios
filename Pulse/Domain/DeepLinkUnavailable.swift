import Foundation

/// Public, non-sensitive explanations for a link that Pulse cannot open.
/// These deliberately do not expose moderation decisions, private work state,
/// or raw transport/server messages.
enum DeepLinkUnavailable: Equatable, Sendable {
    case removed
    case ageRestricted
    case incompatible
    case offline
    case temporarilyUnavailable
    case unavailable

    init(error: Error) {
        if let error = error as? PulseAPIError {
            switch error.serverCode {
            case "not_found", "work_not_found", "artifact_file_missing", "artifact_bundle_missing":
                self = .removed
            case "age_restricted", "age_verification_required":
                self = .ageRestricted
            case "artifact_incompatible", "client_version_unsupported", "minimum_client_version_required":
                self = .incompatible
            case "feature_disabled", "maintenance", "service_unavailable":
                self = .temporarilyUnavailable
            default:
                self = error.statusCode == 503 ? .temporarilyUnavailable : .unavailable
            }
            return
        }

        if let error = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut].contains(error.code) {
            self = .offline
            return
        }

        self = .unavailable
    }

    var title: String {
        switch self {
        case .removed: "This work is no longer available"
        case .ageRestricted: "This work isn’t available for your age settings"
        case .incompatible: "Update Pulse to open this work"
        case .offline: "Can’t open this work while offline"
        case .temporarilyUnavailable: "This work is temporarily unavailable"
        case .unavailable: "Couldn’t open this work"
        }
    }

    var detail: String {
        switch self {
        case .removed:
            "It may have been removed, unshared, or restricted. Return Home to keep exploring Pulse."
        case .ageRestricted:
            "Pulse can’t show this work with the current age settings. Return Home to keep exploring eligible works."
        case .incompatible:
            "A newer version of Pulse is needed to run this interactive work."
        case .offline:
            "Check your connection and try again, or return Home to browse a saved Feed if one is available."
        case .temporarilyUnavailable:
            "Please try again shortly. You can return Home and continue exploring other works."
        case .unavailable:
            "The link may be invalid or the work may no longer be available. Return Home to keep exploring Pulse."
        }
    }

    var retryTitle: String {
        switch self {
        case .incompatible: "Check for update"
        default: "Try again"
        }
    }

    var accessibilityIdentifier: String { "deep-link-unavailable" }
}
