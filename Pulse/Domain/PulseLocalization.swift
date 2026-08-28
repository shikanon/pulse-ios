import Foundation

// The first public release is English-only. Product UI must use this catalog
// for client-owned dynamic copy; user-created content keeps its original
// language and is never machine-translated by the client.
enum PulseLocalization {
    static func validationRule(_ rule: String) -> String? {
        switch rule {
        case "required":
            return String(localized: "validation.required")
        case "invalid", "mismatch":
            return String(localized: "validation.invalid")
        case "unsupported", "not_allowed":
            return String(localized: "validation.unsupported")
        case "out_of_range":
            return String(localized: "validation.out_of_range")
        case "too_long":
            return String(localized: "validation.too_long")
        default:
            return nil
        }
    }

    static func apiError(code: String?, statusCode: Int) -> String {
        switch code {
        case "authentication_required", "apple_identity_invalid", "reauthentication_required":
            return String(localized: "error.sign_in_required")
        case "refresh_invalid":
            return String(localized: "error.session_expired")
        case "username_taken":
            return String(localized: "error.username_taken")
        case "not_found", "artifact_file_missing", "artifact_bundle_missing", "asset_object_unavailable":
            return String(localized: "error.item_unavailable")
        case "forbidden":
            return String(localized: "error.permission_denied")
        case "rate_limited":
            return String(localized: "error.rate_limited")
        case "generation_quota_reached":
            return String(localized: "error.generation_quota_reached")
        case "content_policy_rejected":
            return String(localized: "error.content_policy_rejected")
        case "content_safety_unavailable":
            return String(localized: "error.content_safety_unavailable")
        case "feature_disabled", "authentication_unavailable", "account_deletion_unavailable":
            return String(localized: "error.feature_unavailable")
        case "terms_acceptance_required":
            return String(localized: "error.terms_acceptance_required")
        case "validation_failed", "invalid_json", "unsupported_media_type", "payload_too_large":
            return String(localized: "error.check_and_try_again")
        case "state_conflict", "business_rule_failed":
            return String(localized: "error.action_unavailable")
        case "asset_storage_unavailable", "asset_upload_not_found":
            return String(localized: "error.upload_unavailable")
        default:
            if statusCode == 401 {
                return String(localized: "error.session_expired")
            }
            return String(localized: "error.generic")
        }
    }
}
