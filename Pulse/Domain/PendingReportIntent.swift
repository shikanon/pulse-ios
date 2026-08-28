import Foundation

/// A report composed before authentication. It remains only in the report
/// sheet so a visitor can authenticate and review the same target without
/// silently submitting sensitive free text or carrying it into another
/// account session.
struct PendingReportIntent: Equatable, Sendable {
    enum ReturnDestination: String, Equatable, Sendable {
        case report
    }

    let targetType: String
    let targetID: String
    let targetTitle: String
    let reason: String
    let details: String
    let returnDestination: ReturnDestination

    init(targetType: String, targetID: String, targetTitle: String, reason: String, details: String) {
        self.targetType = targetType
        self.targetID = targetID
        self.targetTitle = targetTitle
        self.reason = reason
        self.details = details
        self.returnDestination = .report
    }
}
