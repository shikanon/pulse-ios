import Foundation

struct GenerationAsset: Identifiable, Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case uploading, ready }
    let id: UUID
    let owner: String
    let fileName: String
    let mediaType: String
    let sizeBytes: Int
    let status: Status
    let summary: String?
    let confidence: Double?
}

struct GenerationJob: Identifiable, Codable, Equatable, Sendable {
    enum Stage: String, Codable, CaseIterable, Sendable {
        case queued, processingAssets = "processing_assets", planning, coding, verifying, repairing
        case fallbackBuilding = "fallback_building", succeeded, fallbackReady = "fallback_ready", failed, cancelled

        var isTerminal: Bool { [.succeeded, .fallbackReady, .failed, .cancelled].contains(self) }
        var productTitle: String {
            switch self {
            case .queued: "Preparing your creation"
            case .processingAssets: "Understanding your materials"
            case .planning: "Designing the project plan"
            case .coding: "Building the interactive app"
            case .verifying: "Running automatic checks"
            case .repairing: "Repairing the experience"
            case .fallbackBuilding: "Preparing a safe version"
            case .succeeded: "Ready to preview"
            case .fallbackReady: "Safe version ready"
            case .failed: "Generation needs attention"
            case .cancelled: "Generation cancelled"
            }
        }
    }

    let id: UUID
    let workID: UUID
    let runID: UUID
    let instruction: String
    let assetIDs: [UUID]
    let creationMode: InteractiveApp.CreationMode
    let stage: Stage
    let statusMessage: String
    let verificationGrade: InteractiveApp.VerificationGrade
    let planID: UUID?
    let artifactID: UUID?
    let verificationID: UUID?
    let errorCategory: String?
    let retryable: Bool
    let createdAt: Date
    let updatedAt: Date
    let terminalAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, instruction, creationMode, stage, statusMessage, verificationGrade
        case errorCategory, retryable, createdAt, updatedAt, terminalAt
        case workID = "workId"
        case runID = "runId"
        case assetIDs = "assetIds"
        case planID = "planId"
        case artifactID = "artifactId"
        case verificationID = "verificationId"
    }
}

struct GenerationPlan: Identifiable, Codable, Equatable, Sendable {
    struct Screen: Codable, Equatable, Identifiable, Sendable { let id: String; let purpose: String }
    struct Interaction: Codable, Equatable, Identifiable, Sendable { let id: String; let trigger: String; let effect: String }
    struct AssetMapping: Codable, Equatable, Identifiable, Sendable {
        let assetID: UUID
        let usage: String
        let summary: String
        var id: UUID { assetID }

        enum CodingKeys: String, CodingKey { case assetID = "assetId", usage, summary }
    }
    struct AcceptanceCase: Codable, Equatable, Identifiable, Sendable { let id: String; let priority: String; let action: String; let assert: String }
    let id: UUID
    let jobID: UUID
    let schemaVersion: String
    let title: String
    let objective: String
    let screens: [Screen]
    let interactions: [Interaction]
    let assetMappings: [AssetMapping]
    let acceptanceCases: [AcceptanceCase]
    let constraints: [String]
    let scaffoldVersion: String

    enum CodingKeys: String, CodingKey {
        case id, schemaVersion, title, objective, screens, interactions, assetMappings, acceptanceCases, constraints, scaffoldVersion
        case jobID = "jobId"
    }
}
