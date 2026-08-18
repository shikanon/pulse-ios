import Foundation

@Observable
final class AppModel {
    var feed: [InteractiveApp] = InteractiveApp.seed
    var creatorName = "you"
    var api = PulseAPIClient()

    func like(_ appID: UUID) {
        guard let index = feed.firstIndex(where: { $0.id == appID }) else { return }
        feed[index].isLiked.toggle()
        feed[index].likes += feed[index].isLiked ? 1 : -1
    }

    func remix(_ original: InteractiveApp) -> InteractiveApp {
        let remix = InteractiveApp(
            title: "(original.title) — remix",
            creator: creatorName,
            prompt: original.prompt,
            theme: original.theme,
            tint: original.tint,
            likes: 0,
            remixes: 0,
            parentID: original.id,
            interaction: original.interaction
        )
        feed.insert(remix, at: 0)
        return remix
    }
}
