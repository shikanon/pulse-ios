import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var feed: [InteractiveApp] = InteractiveApp.seed
    var myWorks: [InteractiveApp] = []
    var creatorName = "you"
    var comments: [UUID: [AppComment]] = [:]
    var publicAssets: [GenerationAsset] = []
    var privateAssets: [GenerationAsset] = []
    var isLoadingAssetLibrary = false
    var assetLibraryError: String?
    var isLoadingFeed = false
    var feedError: String?
    var profileError: String?
    let api = PulseAPIClient()

    func loadFeed() async {
        isLoadingFeed = true
        defer { isLoadingFeed = false }
        do {
            feed = try await api.fetchFeed()
            feedError = nil
        } catch {
            feedError = error.localizedDescription
        }
    }

    func toggleLike(_ appID: UUID) async {
        guard let index = feed.firstIndex(where: { $0.id == appID }) else { return }
        let previous = feed[index]
        feed[index].isLiked.toggle()
        feed[index].likes += feed[index].isLiked ? 1 : -1
        do {
            let authoritative = try await api.setLike(workID: appID, liked: feed[index].isLiked)
            replace(authoritative)
        } catch {
            if let current = feed.firstIndex(where: { $0.id == appID }) { feed[current] = previous }
            feedError = error.localizedDescription
        }
    }

    func comments(for appID: UUID) -> [AppComment] { comments[appID] ?? [] }

    func loadComments(for appID: UUID) async throws {
        comments[appID] = try await api.fetchComments(workID: appID)
    }

    func addComment(to appID: UUID, body: String, score: Int) async throws {
        let comment = try await api.comment(on: appID, score: score, body: body)
        comments[appID, default: []].insert(comment, at: 0)
        if let index = feed.firstIndex(where: { $0.id == appID }) { feed[index].comments += 1 }
    }

    func registerAsset(fileName: String, mediaType: String, data: Data) async throws -> GenerationAsset {
        let asset = try await api.registerAsset(fileName: fileName, mediaType: mediaType, data: data)
        privateAssets.removeAll { $0.id == asset.id }
        privateAssets.insert(asset, at: 0)
        return asset
    }

    func loadAssetLibrary() async {
        isLoadingAssetLibrary = true
        defer { isLoadingAssetLibrary = false }
        do {
            let assets = try await api.fetchAssetLibrary()
            publicAssets = assets.filter { $0.library == .public }
            privateAssets = assets.filter { $0.library == .private }
            assetLibraryError = nil
        } catch {
            assetLibraryError = error.localizedDescription
        }
    }

    func beginGeneration(instruction: String, parent: InteractiveApp?, assets: [GenerationAsset]) async throws -> (InteractiveApp, GenerationJob) {
        let work = try await api.createWork(instruction: instruction, parent: parent)
        let generation = try await api.startGeneration(workID: work.id, instruction: instruction, assetIDs: assets.map(\.id))
        replace(work)
        return (work, generation)
    }

    func refreshGeneration(_ id: UUID) async throws -> GenerationJob { try await api.generation(id: id) }
    func plan(for jobID: UUID) async throws -> GenerationPlan { try await api.plan(jobID: jobID) }

    func artifactURL(for artifactID: UUID) -> URL {
        api.artifactEntryURL(id: artifactID)
    }

    func artifactURL(for work: InteractiveApp) -> URL? {
        guard let artifactID = work.artifactID else { return nil }
        if let entry = work.artifactEntryURL,
           let resolved = api.resolveArtifactEntryURL(entry, artifactID: artifactID) { return resolved }
        return api.artifactEntryURL(id: artifactID)
    }

    func publish(_ workID: UUID) async throws -> InteractiveApp {
        let work = try await api.publish(workID: workID)
        replace(work)
        await loadFeed()
        await loadMyWorks()
        return work
    }

    func loadMyWorks() async {
        do {
            myWorks = try await api.fetchMyWorks()
            profileError = nil
        } catch {
            profileError = error.localizedDescription
        }
    }

    private func replace(_ work: InteractiveApp) {
        if let index = feed.firstIndex(where: { $0.id == work.id }) { feed[index] = work }
        if let index = myWorks.firstIndex(where: { $0.id == work.id }) { myWorks[index] = work }
        else if work.creator == creatorName { myWorks.insert(work, at: 0) }
    }
}
