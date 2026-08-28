import Foundation

/// A comment composed before authentication. It stays in the presented
/// Comments sheet only: no guest text is uploaded, written to Keychain, or
/// carried into a different account session.
struct PendingCommentIntent: Equatable, Sendable {
    enum ReturnDestination: String, Equatable, Sendable {
        case comments
    }

    let workID: UUID
    let body: String
    let score: Int
    let idempotencyKey: String
    let returnDestination: ReturnDestination

    init(workID: UUID, body: String, score: Int, idempotencyKey: String) {
        self.workID = workID
        self.body = body
        self.score = score
        self.idempotencyKey = idempotencyKey
        self.returnDestination = .comments
    }
}
