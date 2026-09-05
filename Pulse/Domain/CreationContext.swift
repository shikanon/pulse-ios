import Foundation

/// Author-owned direction, carried with the generation instruction rather than
/// the public work prompt. The original idea remains suitable for public display.
struct CreationContext: Codable, Equatable, Sendable {
    struct Material: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        var name: String
        var role: Role
        var placement: String
    }

    enum Role: String, Codable, CaseIterable, Sendable {
        case automatic, character, background, reaction, reference, music, sound, clip

        var title: String {
            switch self {
            case .automatic: "Choose from my idea"
            case .character: "Character or object"
            case .background: "Background"
            case .reaction: "Reaction or reward"
            case .reference: "Visual reference only"
            case .music: "Background music"
            case .sound: "Sound effect"
            case .clip: "Video moment"
            }
        }

        static func choices(for kind: GenerationAsset.Kind) -> [Self] {
            switch kind {
            case .image: [.automatic, .character, .background, .reaction, .reference]
            case .audio: [.music, .sound]
            case .video: [.clip, .reference]
            }
        }
    }

    var preserve = ""
    var materials: [Material] = []
    private static let separator = "\n\n--- Pulse creation context ---\n"

    func selected(for assets: [GenerationAsset]) -> Self {
        Self(preserve: String(preserve.prefix(800)), materials: assets.map { asset in
            var item = materials.first { $0.id == asset.id } ?? Material(
                id: asset.id, name: asset.displayName,
                role: Role.choices(for: asset.kind)[0], placement: ""
            )
            item.name = asset.displayName
            if !Role.choices(for: asset.kind).contains(item.role) { item.role = Role.choices(for: asset.kind)[0] }
            item.placement = String(item.placement.prefix(400))
            return item
        })
    }

    func instruction(for message: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard !preserve.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !materials.isEmpty,
              let data = try? encoder.encode(self), let json = String(data: data, encoding: .utf8)
        else { return message }
        return message + Self.separator + json + "\n" + Self.guidance
    }

    static func parse(_ instruction: String) -> (message: String, context: Self?) {
        guard let range = instruction.range(of: separator, options: .backwards) else { return (instruction, nil) }
        let suffix = instruction[range.upperBound...]
        guard let line = suffix.split(separator: "\n").first,
              let data = String(line).data(using: .utf8),
              let context = try? JSONDecoder().decode(Self.self, from: data)
        else { return (instruction, nil) }
        return (String(instruction[..<range.lowerBound]), context)
    }

    private static let guidance = """
    Follow this author's material direction. Match each material id to the approved local asset path in the Plan. Use actual staged files for character/background/reaction/music/sound/clip roles. A reaction must be linked to the described gameplay event and must not block controls. A reference is visual inspiration only: inspect it if supported; do not embed it in the runtime or claim visual understanding you did not perform. Keep audio muted until user interaction, provide mute, and avoid autoplay video audio. Preserve the listed existing behavior unless this turn explicitly changes it. In a Remix, keep existing source and embedded media unless the author requests replacement. Verify material placement and event behavior in the working preview.
    """
}
