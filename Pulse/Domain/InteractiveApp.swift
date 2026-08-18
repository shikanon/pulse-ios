import SwiftUI

struct InteractiveApp: Identifiable, Codable, Equatable {
    enum InteractionKind: String, Codable { case garden, constellation, ripple }

    let id: UUID
    var title: String
    var creator: String
    var prompt: String
    var theme: String
    var tint: String
    var likes: Int
    var comments: Int
    var remixes: Int
    var parentID: UUID?
    var interaction: InteractionKind
    var isLiked = false

    init(id: UUID = UUID(), title: String, creator: String, prompt: String, theme: String, tint: String, likes: Int, comments: Int, remixes: Int, parentID: UUID? = nil, interaction: InteractionKind) {
        self.id = id; self.title = title; self.creator = creator; self.prompt = prompt
        self.theme = theme; self.tint = tint; self.likes = likes; self.comments = comments; self.remixes = remixes
        self.parentID = parentID; self.interaction = interaction
    }

    var accent: Color {
        switch tint { case "lime": .pulseLime; case "violet": .pulseViolet; default: .pulseCoral }
    }

    static let seed: [InteractiveApp] = [
        .init(title: "Kinetic Garden", creator: "echoform", prompt: "Grow a chorus with every touch", theme: "A living music garden", tint: "lime", likes: 12400, comments: 237, remixes: 3100, interaction: .garden),
        .init(title: "Night Signals", creator: "maia.liu", prompt: "Connect stars to reveal your mood", theme: "A constellation that remembers", tint: "violet", likes: 8320, comments: 96, remixes: 1180, interaction: .constellation),
        .init(title: "Soft Weather", creator: "nori", prompt: "Move your hand to change the sky", theme: "A tiny pocket forecast", tint: "coral", likes: 4090, comments: 41, remixes: 620, interaction: .ripple)
    ]
}

struct AppComment: Identifiable, Equatable {
    let id = UUID()
    let author: String
    let score: Int
    let body: String
    let createdAt: Date
}

extension Color {
    static let pulseLime = Color(red: 0.70, green: 1.0, blue: 0.08)
    static let pulseViolet = Color(red: 0.58, green: 0.32, blue: 1.0)
    static let pulseCoral = Color(red: 1.0, green: 0.35, blue: 0.46)
}
