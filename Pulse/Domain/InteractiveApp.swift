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
    var generationJobID: UUID?
    var artifactID: UUID?
    var artifactEntryURL: String?
    var publicSlug: String?
    var publicURL: URL?
    var likes: Int
    var comments: Int
    var remixes: Int
    var isLiked: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, creator, prompt, theme, tint, interaction, creationMode
        case parentID = "parentId"
        case rootWorkID = "rootWorkId"
        case originalCreator, allowRemix, status, verificationGrade
        case generationJobID = "generationJobId"
        case artifactID = "artifactId"
        case artifactEntryURL = "artifactEntryUrl"
        case publicSlug
        case publicURL = "publicUrl"
        case likes, comments, remixes
        case isLiked = "viewerHasLiked"
    }

    init(
        id: UUID = UUID(), title: String, creator: String, prompt: String, theme: String,
        tint: String, likes: Int, comments: Int, remixes: Int, parentID: UUID? = nil,
        interaction: InteractionKind, creationMode: CreationMode = .original,
        rootWorkID: UUID? = nil, originalCreator: String? = nil, allowRemix: Bool = true,
        status: Status = .published, verificationGrade: VerificationGrade = .verified,
        generationJobID: UUID? = nil, artifactID: UUID? = nil, artifactEntryURL: String? = nil,
        publicSlug: String? = nil, publicURL: URL? = nil,
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
        self.generationJobID = generationJobID
        self.artifactID = artifactID
        self.artifactEntryURL = artifactEntryURL
        self.publicSlug = publicSlug
        self.publicURL = publicURL
        self.isLiked = isLiked
    }

    var accent: Color {
        switch tint { case "lime": .pulseLime; case "violet": .pulseViolet; default: .pulseCoral }
    }

    static let seed: [InteractiveApp] = [
        .init(title: "Kinetic Garden", creator: "echoform", prompt: "Grow a chorus with every touch", theme: "A living music garden", tint: "lime", likes: 12_400, comments: 237, remixes: 3_100, interaction: .garden),
        .init(title: "Night Signals", creator: "maia.liu", prompt: "Connect stars to reveal your mood", theme: "A constellation that remembers", tint: "violet", likes: 8_320, comments: 96, remixes: 1_180, interaction: .constellation),
        .init(title: "Soft Weather", creator: "nori", prompt: "Move your hand to change the sky", theme: "A tiny pocket forecast", tint: "coral", likes: 4_090, comments: 41, remixes: 620, interaction: .ripple)
    ]
}

struct AppComment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let workID: UUID
    let author: String
    let score: Int
    let body: String
    let status: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, author, score, body, status, createdAt
        case workID = "workId"
    }
}

extension Color {
    static let pulseLime = Color(red: 0.70, green: 1.0, blue: 0.08)
    static let pulseViolet = Color(red: 0.58, green: 0.32, blue: 1.0)
    static let pulseCoral = Color(red: 1.0, green: 0.35, blue: 0.46)
}
