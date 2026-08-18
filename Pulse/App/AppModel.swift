import Foundation

@Observable
final class AppModel {
    var feed: [InteractiveApp] = InteractiveApp.seed
    var creatorName = "you"
    var api = PulseAPIClient()
    var comments: [UUID: [AppComment]] = [:]

    init() {
        guard let featuredApp = feed.first else { return }
        comments[featuredApp.id] = [
            AppComment(author: "mika", score: 5, body: "The sound response feels wonderfully alive. I keep finding new rhythms.", createdAt: .now),
            AppComment(author: "kai.studio", score: 4, body: "A beautiful interaction — I would love a slower mode for winding down.", createdAt: .now)
        ]
    }

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
            comments: 0,
            remixes: 0,
            parentID: original.id,
            interaction: original.interaction
        )
        feed.insert(remix, at: 0)
        return remix
    }

    func comments(for appID: UUID) -> [AppComment] { comments[appID] ?? [] }

    func addComment(to appID: UUID, body: String, score: Int) {
        let comment = AppComment(author: creatorName, score: score, body: body, createdAt: .now)
        comments[appID, default: []].insert(comment, at: 0)
        guard let index = feed.firstIndex(where: { $0.id == appID }) else { return }
        feed[index].comments += 1
    }
}
