import Foundation

// Keep artifact failures understandable without surfacing server messages,
// internal identifiers, or the existence of a private work. The API may add
// the stable codes below over time; status-code fallbacks preserve a safe
// experience until every deployment emits them.
enum ArtifactUnavailable: Equatable, Sendable {
    case removed
    case restricted
    case incompatible
    case offline
    case temporarilyUnavailable
    case unavailable

    init(error: Error) {
        if let apiError = error as? PulseAPIError {
            switch apiError.serverCode {
            case "not_found", "artifact_file_missing", "artifact_bundle_missing":
                self = .removed
            case "age_restricted", "age_verification_required", "forbidden":
                self = .restricted
            case "artifact_incompatible", "client_version_unsupported", "minimum_client_version_required":
                self = .incompatible
            case "feature_disabled", "maintenance", "service_unavailable", "artifact_storage_unavailable":
                self = .temporarilyUnavailable
            default:
                switch apiError.statusCode {
                case 404:
                    self = .removed
                case 401, 403:
                    self = .restricted
                case 422:
                    self = .incompatible
                case let status? where (500...599).contains(status):
                    self = .temporarilyUnavailable
                default:
                    self = .unavailable
                }
            }
            return
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut:
                self = .offline
            default:
                self = .unavailable
            }
            return
        }

        self = .unavailable
    }

    var title: String {
        switch self {
        case .removed:
            "Interactive version removed"
        case .restricted:
            "Interactive version restricted"
        case .incompatible:
            "Update Pulse to play this"
        case .offline:
            "Interactive version needs a connection"
        case .temporarilyUnavailable:
            "Interactive version temporarily unavailable"
        case .unavailable:
            "Interactive version unavailable"
        }
    }

    var detail: String {
        switch self {
        case .removed:
            "This interactive version is no longer available."
        case .restricted:
            "This interactive version is not available to this account."
        case .incompatible:
            "Update Pulse, then try this interactive version again."
        case .offline:
            "Reconnect to load the interactive version."
        case .temporarilyUnavailable:
            "Please try the interactive version again shortly."
        case .unavailable:
            "The interactive version could not be loaded. Please try again."
        }
    }

    var telemetryCategory: String {
        switch self {
        case .removed: "removed"
        case .restricted: "restricted"
        case .incompatible: "incompatible"
        case .offline: "offline"
        case .temporarilyUnavailable: "temporary"
        case .unavailable: "unavailable"
        }
    }
}
