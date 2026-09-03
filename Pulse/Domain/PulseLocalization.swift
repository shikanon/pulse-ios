import Foundation

// Product UI supports an app-local English/Simplified Chinese choice. Client-
// owned copy uses the catalog; user-created content keeps its original
// language and is never machine-translated by the client.
enum PulseLocalization {
    private static func localized(_ key: String) -> String {
        PulseAppLanguage.selected.localizedString(key)
    }

    static func validationRule(_ rule: String) -> String? {
        switch rule {
        case "required":
            return localized("validation.required")
        case "invalid", "mismatch":
            return localized("validation.invalid")
        case "unsupported", "not_allowed":
            return localized("validation.unsupported")
        case "out_of_range":
            return localized("validation.out_of_range")
        case "too_long":
            return localized("validation.too_long")
        default:
            return nil
        }
    }

    static func apiError(code: String?, statusCode: Int) -> String {
        switch code {
        case "authentication_required", "apple_identity_invalid", "reauthentication_required":
            return localized("error.sign_in_required")
        case "refresh_invalid":
            return localized("error.session_expired")
        case "username_taken":
            return localized("error.username_taken")
        case "not_found", "artifact_file_missing", "artifact_bundle_missing", "asset_object_unavailable":
            return localized("error.item_unavailable")
        case "forbidden":
            return localized("error.permission_denied")
        case "rate_limited":
            return localized("error.rate_limited")
        case "generation_quota_reached":
            return localized("error.generation_quota_reached")
        case "content_policy_rejected":
            return localized("error.content_policy_rejected")
        case "content_safety_unavailable":
            return localized("error.content_safety_unavailable")
        case "feature_disabled", "authentication_unavailable", "account_deletion_unavailable":
            return localized("error.feature_unavailable")
        case "terms_acceptance_required":
            return localized("error.terms_acceptance_required")
        case "validation_failed", "invalid_json", "unsupported_media_type", "payload_too_large":
            return localized("error.check_and_try_again")
        case "state_conflict", "business_rule_failed":
            return localized("error.action_unavailable")
        case "asset_storage_unavailable", "asset_upload_not_found":
            return localized("error.upload_unavailable")
        default:
            if statusCode == 401 {
                return localized("error.session_expired")
            }
            return localized("error.generic")
        }
    }
}
