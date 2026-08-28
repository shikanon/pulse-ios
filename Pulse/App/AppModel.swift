import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var feed: [InteractiveApp] = []
    var myWorks: [InteractiveApp] = []
    var creatorName = "you"
    var comments: [UUID: [AppComment]] = [:]
    var publicAssets: [GenerationAsset] = []
    var privateAssets: [GenerationAsset] = []
    var isLoadingAssetLibrary = false
    var assetLibraryError: String?
    var isLoadingFeed = false
    var isRefreshingFeed = false
    var isLoadingMoreFeed = false
    var feedError: String?
    var feedDataSource: FeedDataSource = .none
    private var nextFeedCursor: String?
    private var hasMoreFeed = true
    private var nextCommentCursors: [UUID: String] = [:]
    private var loadingMoreCommentIDs: Set<UUID> = []
    var profileError: String?
    var pendingRemixSource: InteractiveApp?
    var pendingGenerationRecovery: InteractiveApp?
    var sharedWork: InteractiveApp?
    var reportTarget: WorkReportTarget?
    var deepLinkUnavailable: DeepLinkUnavailable?
    var clientConfiguration: PulseClientConfiguration?
    var isOfflineReadOnly = false
    private var pendingDeepLink: PulseDeepLink?
    let api: PulseAPIClient
    private let feedCache: FeedCacheStore
    private let clientConfigurationCache: ClientConfigurationCacheStore
    private let feedPreviewCache: ArtifactPreviewCache
    private var feedPreviewPrefetchGeneration = 0
    private(set) var feedPreviewRevision = 0

    init(
        api: PulseAPIClient = PulseAPIClient(),
        feedCache: FeedCacheStore? = nil,
        clientConfigurationCache: ClientConfigurationCacheStore? = nil,
        feedPreviewCache: ArtifactPreviewCache = ArtifactPreviewCache()
    ) {
        self.api = api
        self.feedCache = feedCache ?? FeedCacheStore(apiOrigin: api.feedCacheOrigin)
        self.clientConfigurationCache = clientConfigurationCache ?? ClientConfigurationCacheStore(apiOrigin: api.feedCacheOrigin)
        self.feedPreviewCache = feedPreviewCache
    }

    func cacheClientConfiguration(_ configuration: PulseClientConfiguration, savedAt: Date = .now) {
        clientConfigurationCache.save(configuration, savedAt: savedAt)
    }

    func restoreCachedClientConfiguration(now: Date = .now) -> PulseClientConfiguration? {
        clientConfigurationCache.load(now: now)?.configuration
    }

    @discardableResult
    func restoreCachedFeed(now: Date = .now) -> Bool {
        guard let cached = feedCache.load(now: now) else { return false }
        feed = cached.data
        nextFeedCursor = cached.nextCursor
        hasMoreFeed = cached.nextCursor != nil
        feedDataSource = .cached(savedAt: cached.savedAt)
        return true
    }

    func loadFeed() async {
        guard !isLoadingFeed, !isRefreshingFeed else { return }
        let isRefreshingExistingFeed = !feed.isEmpty
        if isRefreshingExistingFeed {
            isRefreshingFeed = true
        } else {
            isLoadingFeed = true
        }
        defer {
            if isRefreshingExistingFeed {
                isRefreshingFeed = false
            } else {
                isLoadingFeed = false
            }
        }
        do {
            let page = try await api.fetchFeedPage()
            feed = page.data
            nextFeedCursor = page.nextCursor
            hasMoreFeed = page.nextCursor != nil
            feedDataSource = .live
            feedError = nil
            cacheCurrentFeed()
        } catch {
            if !feed.isEmpty {
                feedError = "Couldn’t refresh the latest works. Your current Feed is still available."
            } else if feedDataSource.cachedAt != nil {
                feedError = "Couldn’t refresh the latest works. You’re viewing a saved copy."
            } else {
                feedError = "Couldn’t load Pulse. Check your connection and try again."
            }
        }
    }

    // Pull-to-refresh is intentionally a read-only network action. An offline
    // launch keeps its safety-limited cached Feed and the visible reconnect
    // control rather than attempting a request that cannot succeed.
    func refreshFeed() async {
        guard !isOfflineReadOnly else { return }
        await loadFeed()
    }

    func loadMoreFeed() async {
        guard !isLoadingFeed, !isRefreshingFeed, !isLoadingMoreFeed, hasMoreFeed, let nextFeedCursor else { return }
        isLoadingMoreFeed = true
        defer { isLoadingMoreFeed = false }
        do {
            let page = try await api.fetchFeedPage(cursor: nextFeedCursor)
            let knownIDs = Set(feed.map(\.id))
            feed.append(contentsOf: page.data.filter { !knownIDs.contains($0.id) })
            self.nextFeedCursor = page.nextCursor
            hasMoreFeed = page.nextCursor != nil
            feedDataSource = .live
            feedError = nil
            cacheCurrentFeed()
        } catch {
            // Keep the feed the user was already reading visible and offer a
            // retry instead of replacing it with an empty failure screen.
            feedError = "Couldn’t load more works. Your current Feed is still available."
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

    func canLoadMoreComments(for appID: UUID) -> Bool { nextCommentCursors[appID] != nil }

    func isLoadingMoreComments(for appID: UUID) -> Bool { loadingMoreCommentIDs.contains(appID) }

    func loadComments(for appID: UUID) async throws {
        let page = try await api.fetchCommentsPage(workID: appID)
        comments[appID] = page.data
        setNextCommentCursor(page.nextCursor, for: appID)
    }

    func loadMoreComments(for appID: UUID) async throws {
        guard let cursor = nextCommentCursors[appID], !loadingMoreCommentIDs.contains(appID) else { return }
        loadingMoreCommentIDs.insert(appID)
        defer { loadingMoreCommentIDs.remove(appID) }

        let page = try await api.fetchCommentsPage(workID: appID, cursor: cursor)
        let knownIDs = Set(comments[appID, default: []].map(\.id))
        comments[appID, default: []].append(contentsOf: page.data.filter { !knownIDs.contains($0.id) })
        setNextCommentCursor(page.nextCursor, for: appID)
    }

    func addComment(to appID: UUID, body: String, score: Int, idempotencyKey: String) async throws {
        let comment = try await api.comment(on: appID, score: score, body: body, idempotencyKey: idempotencyKey)
        comments[appID, default: []].insert(comment, at: 0)
        if let index = feed.firstIndex(where: { $0.id == appID }) { feed[index].comments += 1 }
    }

    func deleteComment(from appID: UUID, commentID: UUID) async throws {
        try await api.deleteComment(workID: appID, commentID: commentID)
        comments[appID]?.removeAll { $0.id == commentID }
        if let index = feed.firstIndex(where: { $0.id == appID }), feed[index].comments > 0 { feed[index].comments -= 1 }
    }

    func report(targetType: String, targetID: String, reason: String, details: String) async throws -> ReporterReport {
        try await api.report(targetType: targetType, targetID: targetID, reason: reason, details: details)
    }

    func block(username: String) async throws {
        try await api.block(username: username)
        feed.removeAll { $0.creator == username }
        for key in comments.keys {
            comments[key]?.removeAll { $0.author == username }
        }
    }

    private func setNextCommentCursor(_ cursor: String?, for appID: UUID) {
        if let cursor, !cursor.isEmpty {
            nextCommentCursors[appID] = cursor
        } else {
            nextCommentCursors.removeValue(forKey: appID)
        }
    }

    func registerAsset(fileName: String, mediaType: String, data: Data) async throws -> GenerationAsset {
        let asset = try await api.registerAsset(fileName: fileName, mediaType: mediaType, data: data)
        privateAssets.removeAll { $0.id == asset.id }
        privateAssets.insert(asset, at: 0)
        return asset
    }

    func registerAssetWithProgress(
        fileName: String,
        mediaType: String,
        data: Data,
        recoveryContext: AssetUploadRecoveryContext,
        progress: @escaping @MainActor @Sendable (AssetUploadProgress) -> Void
    ) async throws -> GenerationAsset {
        let asset = try await api.registerAssetWithProgress(
            fileName: fileName,
            mediaType: mediaType,
            data: data,
            recoveryContext: recoveryContext,
            progress: progress
        )
        privateAssets.removeAll { $0.id == asset.id }
        privateAssets.insert(asset, at: 0)
        return asset
    }

    func completeAssetUpload(
        id: UUID,
        progress: @escaping @MainActor @Sendable (AssetUploadProgress) -> Void
    ) async throws -> GenerationAsset {
        let asset = try await api.completeAssetUpload(id: id, progress: progress)
        privateAssets.removeAll { $0.id == asset.id }
        privateAssets.insert(asset, at: 0)
        return asset
    }

    func resumeBackgroundAssetUpload(
        _ record: BackgroundAssetUploadRecord,
        progress: @escaping @MainActor @Sendable (AssetUploadProgress) -> Void
    ) async throws -> GenerationAsset {
        let asset = try await api.resumeBackgroundAssetUpload(record, progress: progress)
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

    func beginGeneration(
        instruction: String,
        parent: InteractiveApp?,
        parentWorkID: UUID? = nil,
        assets: [GenerationAsset],
        allowRemix: Bool = CreationPreferences.defaultAllowRemix,
        workIdempotencyKey: String,
        generationIdempotencyKey: String
    ) async throws -> (InteractiveApp, GenerationJob) {
        let work = try await api.createWork(
            instruction: instruction,
            parent: parent,
            parentWorkID: parentWorkID,
            allowRemix: allowRemix,
            idempotencyKey: workIdempotencyKey
        )
        let generation = try await api.startGeneration(
            workID: work.id,
            instruction: instruction,
            assetIDs: assets.map(\.id),
            idempotencyKey: generationIdempotencyKey
        )
        replace(work)
        return (work, generation)
    }

    func refreshGeneration(_ id: UUID) async throws -> GenerationJob { try await api.generation(id: id) }
    func cancelGeneration(_ id: UUID) async throws -> GenerationJob { try await api.cancelGeneration(id: id) }
    func retryGeneration(_ id: UUID) async throws -> GenerationJob { try await api.retryGeneration(id: id) }
    func plan(for jobID: UUID) async throws -> GenerationPlan { try await api.plan(jobID: jobID) }
    func verification(for id: UUID) async throws -> VerificationReport { try await api.verification(id: id) }

    func artifactURL(for artifactID: UUID) -> URL {
        api.artifactEntryURL(id: artifactID)
    }

    func artifactURL(for work: InteractiveApp) -> URL? {
        guard let artifactID = work.artifactID else { return nil }
        if let entry = work.artifactEntryURL,
           let resolved = api.resolveArtifactEntryURL(entry, artifactID: artifactID) { return resolved }
        return api.artifactEntryURL(id: artifactID)
    }

    func artifactPreviewData(for work: InteractiveApp) async throws -> Data {
        guard let artifactID = work.artifactID, let previewURL = work.artifactPreviewURL else {
            throw PulseAPIError(message: "This work does not have a static preview yet.")
        }
        return try await api.fetchArtifactPreview(previewURL, artifactID: artifactID)
    }

    /// A Feed poster is a bounded, memory-only optimization. It never runs an
    /// Artifact, never writes an image into the offline snapshot, and accepts
    /// only the server's fixed, same-origin preview.png URL.
    func cachedFeedPreviewData(for work: InteractiveApp) async -> Data? {
        // A cache hit alone is not authority to show a poster. A refreshed
        // Feed response can deliberately omit its URL after a review or
        // visibility change; in that case the previously held bytes must not
        // be reused for this card.
        guard let artifactID = work.artifactID,
              let previewURL = work.artifactPreviewURL,
              api.resolveArtifactPreviewURL(previewURL, artifactID: artifactID) != nil
        else { return nil }
        return await feedPreviewCache.cachedData(for: artifactID)
    }

    func prefetchFeedStaticPreviews(after activeWorkID: UUID, maximumCount: Int = 2) async {
        guard !isOfflineReadOnly,
              maximumCount > 0,
              let activeIndex = feed.firstIndex(where: { $0.id == activeWorkID })
        else { return }

        feedPreviewPrefetchGeneration &+= 1
        let generation = feedPreviewPrefetchGeneration
        let candidates = feed.dropFirst(activeIndex + 1).prefix(maximumCount)
        await feedPreviewCache.cancelInFlight(except: Set(candidates.compactMap(\.artifactID)))
        for work in candidates {
            guard generation == feedPreviewPrefetchGeneration, !Task.isCancelled else { return }
            guard let artifactID = work.artifactID,
                  let previewURL = work.artifactPreviewURL
            else { continue }

            let api = api
            let data = await feedPreviewCache.data(for: artifactID) {
                try? await api.fetchArtifactPreview(previewURL, artifactID: artifactID)
            }
            guard generation == feedPreviewPrefetchGeneration, !Task.isCancelled else { return }
            if data != nil {
                feedPreviewRevision &+= 1
            }
        }
    }

    /// Resolves only the root work that the server derived for a Remix. The
    /// normal Work visibility rule remains authoritative: a withdrawn,
    /// hidden, or otherwise unavailable original returns the same safe error
    /// as any other inaccessible work and is never reconstructed from Remix
    /// metadata.
    func originalWork(for remix: InteractiveApp) async throws -> InteractiveApp {
        guard remix.creationMode == .remix else {
            throw PulseAPIError(serverCode: "not_found", statusCode: 404)
        }
        let original = try await api.fetchWork(id: remix.rootWorkID)
        guard original.id == remix.rootWorkID, original.status == .published else {
            throw PulseAPIError(serverCode: "not_found", statusCode: 404)
        }
        return original
    }

    /// Builds a complete, root-first Remix lineage from server-confirmed
    /// parent links. Every ancestor is fetched through the normal visibility
    /// gate; if a single link was withdrawn, hidden, or malformed, callers
    /// receive one safe unavailable result rather than a partial chain that
    /// could expose a private relationship.
    func remixLineage(for remix: InteractiveApp) async throws -> [InteractiveApp] {
        guard remix.creationMode == .remix, let firstParentID = remix.parentID else {
            throw PulseAPIError(serverCode: "not_found", statusCode: 404)
        }

        let maximumDepth = 12
        var nextID: UUID? = firstParentID
        var seen: Set<UUID> = [remix.id]
        var reverseLineage: [InteractiveApp] = []

        while let workID = nextID, reverseLineage.count < maximumDepth {
            guard seen.insert(workID).inserted else {
                throw PulseAPIError(serverCode: "not_found", statusCode: 404)
            }
            let ancestor = try await api.fetchWork(id: workID)
            guard ancestor.id == workID, ancestor.status == .published else {
                throw PulseAPIError(serverCode: "not_found", statusCode: 404)
            }
            reverseLineage.append(ancestor)

            if ancestor.id == remix.rootWorkID {
                guard ancestor.creationMode == .original else {
                    throw PulseAPIError(serverCode: "not_found", statusCode: 404)
                }
                return Array(reverseLineage.reversed())
            }
            nextID = ancestor.parentID
        }

        throw PulseAPIError(serverCode: "not_found", statusCode: 404)
    }

    func publish(_ workID: UUID) async throws -> InteractiveApp {
        let work = try await api.publish(workID: workID)
        replace(work)
        await loadFeed()
        await loadMyWorks()
        return work
    }

    func unpublish(_ workID: UUID) async throws -> InteractiveApp {
        let work = try await api.unpublish(workID: workID)
        feed.removeAll { $0.id == workID }
        comments[workID] = nil
        replace(work)
        // The mutation response intentionally omits the creator-list-only
        // currentVersion summary. Refreshing the owned list restores that
        // safe summary immediately after the public-link state changes.
        await loadMyWorks()
        return work
    }

    func updateRemixPermission(workID: UUID, allowRemix: Bool) async throws -> InteractiveApp {
        let work = try await api.updateRemixPermission(workID: workID, allowRemix: allowRemix)
        replace(work)
        return work
    }

    func workVersions(for workID: UUID) async throws -> [WorkVersion] {
        try await api.fetchWorkVersions(workID: workID)
    }

    func requestContentReview(_ workID: UUID) async throws -> InteractiveApp {
        let work = try await api.requestContentReview(workID: workID)
        replace(work)
        return work
    }

    func queueDeepLink(_ deepLink: PulseDeepLink) {
        pendingDeepLink = deepLink
        deepLinkUnavailable = nil
    }

    @discardableResult
    func resolvePendingDeepLink() async -> PulseDeepLink? {
        guard let pendingDeepLink else { return nil }
        switch pendingDeepLink {
        case let .remix(workID):
            return await resolveRemixLink(workID: workID) ? pendingDeepLink : nil
        case let .publicWork(slug):
            return await resolvePublicWorkLink(slug: slug) ? pendingDeepLink : nil
        case let .report(slug):
            return await resolveReportLink(slug: slug) ? pendingDeepLink : nil
        }
    }

    @discardableResult
    private func resolveRemixLink(workID: UUID) async -> Bool {
        do {
            let work = try await api.fetchWork(id: workID)
            guard work.status == .published, work.allowRemix else {
                deepLinkUnavailable = .removed
                return false
            }
            pendingRemixSource = work
            pendingDeepLink = nil
            deepLinkUnavailable = nil
            return true
        } catch {
            pendingRemixSource = nil
            deepLinkUnavailable = DeepLinkUnavailable(error: error)
            return false
        }
    }

    @discardableResult
    private func resolvePublicWorkLink(slug: String) async -> Bool {
        do {
            let work = try await api.fetchPublicWork(slug: slug)
            guard work.status == .published, work.publicSlug?.lowercased() == slug.lowercased() else {
                deepLinkUnavailable = .removed
                return false
            }
            sharedWork = work
            pendingDeepLink = nil
            deepLinkUnavailable = nil
            return true
        } catch {
            sharedWork = nil
            deepLinkUnavailable = DeepLinkUnavailable(error: error)
            return false
        }
    }

    @discardableResult
    private func resolveReportLink(slug: String) async -> Bool {
        do {
            let work = try await api.fetchPublicWork(slug: slug)
            guard work.status == .published, work.publicSlug?.lowercased() == slug.lowercased() else {
                deepLinkUnavailable = .removed
                return false
            }
            reportTarget = WorkReportTarget(id: work.id, title: work.title)
            pendingDeepLink = nil
            deepLinkUnavailable = nil
            return true
        } catch {
            reportTarget = nil
            deepLinkUnavailable = DeepLinkUnavailable(error: error)
            return false
        }
    }

    func clearPendingRemix() {
        pendingRemixSource = nil
        deepLinkUnavailable = nil
    }

    func clearSharedWork() {
        sharedWork = nil
        deepLinkUnavailable = nil
    }

    func dismissUnavailableDeepLink() {
        pendingDeepLink = nil
        pendingRemixSource = nil
        sharedWork = nil
        reportTarget = nil
        deepLinkUnavailable = nil
    }

    func recoverGeneration(for work: InteractiveApp) {
        pendingGenerationRecovery = work
    }

    func clearPendingGenerationRecovery() {
        pendingGenerationRecovery = nil
    }

    func loadMyWorks() async {
        do {
            myWorks = try await api.fetchMyWorks()
            profileError = nil
        } catch {
            // Profile is a creator-management surface, but a transport or
            // server diagnostic is not a useful or safe status to display.
            // Preserve existing works and give the creator a single recovery.
            profileError = "Your works couldn’t be refreshed. Check your connection and try again."
        }
    }

    private func replace(_ work: InteractiveApp) {
        if let index = feed.firstIndex(where: { $0.id == work.id }) { feed[index] = work }
        if let index = myWorks.firstIndex(where: { $0.id == work.id }) { myWorks[index] = work }
        else if work.creator == creatorName { myWorks.insert(work, at: 0) }
    }

    private func cacheCurrentFeed() {
        // Feed snapshots are capped at 50 lightweight public records. Keeping
        // this write ordered avoids an older pagination task overwriting a
        // newer snapshot after a later page has already completed.
        feedCache.save(data: feed, nextCursor: nextFeedCursor)
    }
}

struct WorkReportTarget: Identifiable, Equatable {
    let id: UUID
    let title: String
}
