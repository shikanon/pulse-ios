import Foundation

/// A creation intent composed before authentication. It is intentionally
/// memory-only, so a visitor's prompt cannot be restored by another account
/// after leaving the Create surface.
struct PendingCreationIntent: Equatable, Sendable {
    enum ReturnDestination: String, Equatable, Sendable {
        case create
    }

    let parentWorkID: UUID?
    let instruction: String
    let returnDestination: ReturnDestination

    init(parentWorkID: UUID?, instruction: String) {
        self.parentWorkID = parentWorkID
        self.instruction = instruction
        self.returnDestination = .create
    }
}
