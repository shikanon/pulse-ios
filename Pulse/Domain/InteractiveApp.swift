import SwiftUI

struct InteractiveApp: Identifiable, Codable, Equatable, Sendable {
    struct InteractionKind: RawRepresentable, Codable, Equatable, Sendable {
        let rawValue: String

        init(rawValue: String) { self.rawValue = rawValue }

        static let garden = Self(rawValue: "garden")
        static let constellation = Self(rawValue: "constellation")
        static let ripple = Self(rawValue: "ripple")
    }
    enum CreationMode: String, Codable, Sendable { case original, remix }
    enum Status: String, Codable, Sendable { case draft, processing, published, hidden, deleted }
    enum VerificationGrade: String, Codable, Sendable { case pending, verified, degraded, fallback }
    enum ContentReviewStatus: String, Codable, Sendable { case pending, approved, rejected }
    enum AgeRating: String, Codable, Sendable { case unrated, fourPlus = "4+", ninePlus = "9+", thirteenPlus = "13+", sixteenPlus = "16+", eighteenPlus = "18+" }

    let id: UUID
    var title: String
    var creator: String
    var prompt: String
    var theme: String
    var tint: String
    var interaction: InteractionKind
    var creationMode: CreationMode
    var parentID: UUID?
    var rootWorkID: UUID
    var originalCreator: String
    var allowRemix: Bool
    var status: Status
    var verificationGrade: VerificationGrade
    var contentReviewStatus: ContentReviewStatus?
    var ageRating: AgeRating?
    var contentReviewRequestedAt: Date?
    var generationJobID: UUID?
    var artifactID: UUID?
    var artifactEntryURL: String?
    // Returned on the authenticated creator list and eligible public Feed
    // cards. This is a server-rendered, immutable PNG—not a locally invented
    // card image—and remains separate from the interactive Artifact entry URL.
    var artifactPreviewURL: String?
    var publicSlug: String?
    var publicURL: URL?
    var currentVersion: Int?
    var publicLinkRevokedAt: Date?
    var createdAt: Date?
    var updatedAt: Date?
    var likes: Int
    var comments: Int
    var remixes: Int
    var isLiked: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, creator, prompt, theme, tint, interaction, creationMode
        case parentID = "parentId"
        case rootWorkID = "rootWorkId"
        case originalCreator, allowRemix, status, verificationGrade, contentReviewStatus, ageRating, contentReviewRequestedAt
        case generationJobID = "generationJobId"
        case artifactID = "artifactId"
        case artifactEntryURL = "artifactEntryUrl"
        case artifactPreviewURL = "artifactPreviewUrl"
        case publicSlug
        case publicURL = "publicUrl"
        case currentVersion
        case publicLinkRevokedAt
        case createdAt, updatedAt
        case likes, comments, remixes
        case isLiked = "viewerHasLiked"
    }

    init(
        id: UUID = UUID(), title: String, creator: String, prompt: String, theme: String,
        tint: String, likes: Int, comments: Int, remixes: Int, parentID: UUID? = nil,
        interaction: InteractionKind, creationMode: CreationMode = .original,
        rootWorkID: UUID? = nil, originalCreator: String? = nil, allowRemix: Bool = true,
        status: Status = .published, verificationGrade: VerificationGrade = .verified,
        contentReviewStatus: ContentReviewStatus? = nil, ageRating: AgeRating? = nil, contentReviewRequestedAt: Date? = nil,
        generationJobID: UUID? = nil, artifactID: UUID? = nil, artifactEntryURL: String? = nil, artifactPreviewURL: String? = nil,
        publicSlug: String? = nil, publicURL: URL? = nil, currentVersion: Int? = nil, publicLinkRevokedAt: Date? = nil,
        createdAt: Date? = nil, updatedAt: Date? = nil,
        isLiked: Bool = false
    ) {
        self.id = id
        self.title = title
        self.creator = creator
        self.prompt = prompt
        self.theme = theme
        self.tint = tint
        self.likes = likes
        self.comments = comments
        self.remixes = remixes
        self.parentID = parentID
        self.interaction = interaction
        self.creationMode = creationMode
        self.rootWorkID = rootWorkID ?? id
        self.originalCreator = originalCreator ?? creator
        self.allowRemix = allowRemix
        self.status = status
        self.verificationGrade = verificationGrade
        self.contentReviewStatus = contentReviewStatus
        self.ageRating = ageRating
        self.contentReviewRequestedAt = contentReviewRequestedAt
        self.generationJobID = generationJobID
        self.artifactID = artifactID
        self.artifactEntryURL = artifactEntryURL
        self.artifactPreviewURL = artifactPreviewURL
        self.publicSlug = publicSlug
        self.publicURL = publicURL
        self.currentVersion = currentVersion
        self.publicLinkRevokedAt = publicLinkRevokedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isLiked = isLiked
    }

    var accent: Color {
        switch tint { case "lime": .pulseLime; case "violet": .pulseViolet; default: .pulseCoral }
    }

}

struct AppComment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let workID: UUID
    let author: String
    let score: Int
    let body: String
    let status: String
    let createdAt: Date
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, author, score, body, status, createdAt, updatedAt
        case workID = "workId"
    }

    var isHiddenFromOthers: Bool { status == "hidden" }
}

struct CommunityReport: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let reporter: String
    let targetType: String
    let targetID: String
    let reason: String
    let details: String
    let status: String
    let createdAt: Date
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, reporter, targetType, reason, details, status, createdAt, updatedAt
        case targetID = "targetId"
    }
}

// This is deliberately narrower than CommunityReport. The report-history API
// never exposes a moderator identity, internal case note, or what action was
// taken against another person; it lets the reporting user track only their
// own case's safe lifecycle state.
struct ReporterReport: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let targetType: String
    let reason: String
    let status: String
    let createdAt: Date
    let updatedAt: Date
    let resolvedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, targetType, reason, status, createdAt, updatedAt, resolvedAt
    }

    var statusTitle: String {
        switch status {
        case "open": "Received"
        case "investigating": "Under review"
        case "actioned", "dismissed": "Review complete"
        default: "Review status updated"
        }
    }

    var statusDetail: String {
        switch status {
        case "open": "Pulse has received your report."
        case "investigating": "Pulse is reviewing this report."
        case "actioned", "dismissed": "Pulse has completed its review."
        default: "Pulse has updated this report."
        }
    }
}

extension Color {
    static let pulseLime = Color(red: 0.70, green: 1.0, blue: 0.08)
    static let pulseViolet = Color(red: 0.58, green: 0.32, blue: 1.0)
    static let pulseCoral = Color(red: 1.0, green: 0.35, blue: 0.46)
}
