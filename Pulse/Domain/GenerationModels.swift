import Foundation

struct GenerationCapabilities: Decodable, Equatable, Sendable {
    enum Mode: String, Decodable, Sendable {
        case live
        case deterministicLocal = "deterministic-local"
    }

    let mode: Mode
    let modelBacked: Bool
    var materialUploads: Bool? = nil

    var usesLiveModel: Bool { mode == .live && modelBacked }
}

struct GenerationAsset: Identifiable, Decodable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case uploading, ready }
    enum Library: String, Codable, Sendable { case `public`, `private` }
    enum Source: String, Codable, Sendable { case official, upload }
    enum Kind: String, Codable, Sendable { case image, audio, video }

    let id: UUID
    let owner: String
    let library: Library
    let source: Source
    let kind: Kind
    let displayName: String
    let fileName: String
    let mediaType: String
    let sizeBytes: Int
    let status: Status
    let summary: String?
    let license: String?
    let deliveryURL: URL?
    let confidence: Double?

    private enum CodingKeys: String, CodingKey {
        case id, owner, library, source, kind, displayName, fileName, mediaType, sizeBytes, status, summary, license, confidence
        case deliveryURL = "deliveryUrl"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        owner = try values.decode(String.self, forKey: .owner)
        fileName = try values.decode(String.self, forKey: .fileName)
        mediaType = try values.decode(String.self, forKey: .mediaType)
        sizeBytes = try values.decode(Int.self, forKey: .sizeBytes)
        status = try values.decode(Status.self, forKey: .status)
        library = try values.decodeIfPresent(Library.self, forKey: .library) ?? .private
        source = try values.decodeIfPresent(Source.self, forKey: .source) ?? .upload
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? Self.kind(for: mediaType)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName) ?? fileName
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        license = try values.decodeIfPresent(String.self, forKey: .license)
        deliveryURL = try values.decodeIfPresent(URL.self, forKey: .deliveryURL)
        confidence = try values.decodeIfPresent(Double.self, forKey: .confidence)
    }

    var iconName: String {
        switch kind {
        case .image: "photo.fill"
        case .audio: "music.note"
        case .video: "video.fill"
        }
    }

    private static func kind(for mediaType: String) -> Kind {
        if mediaType.hasPrefix("audio/") { return .audio }
        if mediaType.hasPrefix("video/") { return .video }
        return .image
    }
}

extension GenerationAsset: Encodable {
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(owner, forKey: .owner)
        try values.encode(library, forKey: .library)
        try values.encode(source, forKey: .source)
        try values.encode(kind, forKey: .kind)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(fileName, forKey: .fileName)
        try values.encode(mediaType, forKey: .mediaType)
        try values.encode(sizeBytes, forKey: .sizeBytes)
        try values.encode(status, forKey: .status)
        try values.encodeIfPresent(summary, forKey: .summary)
        try values.encodeIfPresent(license, forKey: .license)
        try values.encodeIfPresent(deliveryURL, forKey: .deliveryURL)
        try values.encodeIfPresent(confidence, forKey: .confidence)
    }
}

struct GenerationJob: Identifiable, Codable, Equatable, Sendable {
    enum Stage: String, Codable, CaseIterable, Sendable {
        case queued, processingAssets = "processing_assets", planning, coding, verifying, repairing
        case fallbackBuilding = "fallback_building", succeeded, fallbackReady = "fallback_ready", failed, cancelled

        var isTerminal: Bool { [.succeeded, .fallbackReady, .failed, .cancelled].contains(self) }
        var productTitle: String {
            switch self {
            case .queued: "Preparing your creation"
            case .processingAssets: "Preparing your materials"
            case .planning: "Designing the project plan"
            case .coding: "Building the interactive app"
            case .verifying: "Running automatic checks"
            case .repairing: "Repairing the experience"
            case .fallbackBuilding: "Preparing a safe version"
            case .succeeded: "Ready to preview"
            case .fallbackReady: "Generation needs changes"
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

// WorkVersion is the creator-facing, read-only summary of a generation
// candidate. Unlike GenerationJob it intentionally has no prompt, asset list,
// error category, or operational status message, so the profile timeline can
// remain useful without becoming a route to private inputs or server details.
struct WorkVersion: Identifiable, Decodable, Equatable, Sendable {
    let version: Int
    let generationID: UUID
    let artifactID: UUID?
    let verificationID: UUID?
    let verificationGrade: InteractiveApp.VerificationGrade
    let stage: GenerationJob.Stage
    let isCurrent: Bool
    let isPublished: Bool
    let createdAt: Date

    var id: UUID { generationID }

    enum CodingKeys: String, CodingKey {
        case version, verificationGrade, stage, isCurrent, isPublished, createdAt
        case generationID = "generationId"
        case artifactID = "artifactId"
        case verificationID = "verificationId"
    }
}

// GenerationFailurePresentation is the only user-facing interpretation of the
// backend's operational failure category. The category remains useful for
// server observability, but it can reveal implementation details and is not a
// stable piece of product copy.
enum GenerationFailurePresentation: Equatable, Sendable {
    case materialsUnavailable
    case cancelled
    case needsChanges
    case temporarilyUnavailable
    case unavailable

    init(stage: GenerationJob.Stage, errorCategory: String?) {
        guard stage != .cancelled else {
            self = .cancelled
            return
        }

        switch errorCategory {
        case "generation_input_unavailable", "asset_storage_unavailable":
            self = .materialsUnavailable
        case "artifact_safety_check_failed", "artifact_manifest_invalid", "verification_hard_gate_failed", "verifier_report_rejected", "fallback_verification_failed", "fallback_quality_below_threshold":
            self = .needsChanges
        case "coding_agent_failed", "local_artifact_export_failed", "artifact_persist_failed", "verifier_unavailable", "fallback_transition_failed", "fallback_build_failed", "fallback_verifier_unavailable", "fallback_artifact_persist_failed":
            self = .temporarilyUnavailable
        default:
            self = .unavailable
        }
    }

    var title: String {
        switch self {
        case .materialsUnavailable:
            "Materials need attention"
        case .cancelled:
            "Generation cancelled"
        case .needsChanges:
            "This version needs changes"
        case .temporarilyUnavailable:
            "Pulse needs a moment"
        case .unavailable:
            "This version was not created"
        }
    }

    var detail: String {
        switch self {
        case .materialsUnavailable:
            "A selected material could not be read. Remove it or upload it again, then generate. Your idea is still here; retrying unchanged will not resolve this issue."
        case .cancelled:
            "Nothing was published. Your original instruction is still here, so you can adjust it and start again when ready."
        case .needsChanges:
            "This version did not pass Pulse’s required safety or quality checks. Nothing was published. Update the idea or materials, then create a new version."
        case .temporarilyUnavailable:
            "Pulse could not finish this generation right now. Nothing was published. Your idea and materials are still private, and you can try again."
        case .unavailable:
            "Pulse could not create this version. Nothing was published. Your idea and materials are still private. You can edit the idea or try again."
        }
    }

    var symbolName: String {
        switch self {
        case .materialsUnavailable:
            "photo.badge.exclamationmark"
        case .cancelled:
            "xmark.circle.fill"
        case .needsChanges:
            "shield.lefthalf.filled"
        case .temporarilyUnavailable:
            "clock.arrow.circlepath"
        case .unavailable:
            "exclamationmark.triangle.fill"
        }
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

struct VerificationReport: Identifiable, Codable, Equatable, Sendable {
    struct Check: Codable, Equatable, Identifiable, Sendable {
        let name: String
        let status: String
        let hardGate: Bool
        let durationMS: Int
        let summary: String
        var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name, status, hardGate, summary
            case durationMS = "durationMs"
        }
    }

    let id: UUID
    let jobID: UUID
    let runID: UUID
    let grade: InteractiveApp.VerificationGrade
    let score: Double
    let checks: [Check]
    let verifierVersion: String
    let artifactHash: String
    let summary: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, grade, score, checks, verifierVersion, artifactHash, summary, createdAt
        case jobID = "jobId"
        case runID = "runId"
    }
}
