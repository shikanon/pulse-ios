import Foundation

/// Keeps a very small, memory-only set of renderer-owned Feed posters. These
/// PNGs are safe to display only while their public Artifact grant remains
/// valid, so they are deliberately never written to disk or joined to the
/// offline Feed snapshot.
actor ArtifactPreviewCache {
    static let maximumEntryBytes = 1_048_576
    static let defaultMaximumStoredBytes = 3 * 1_024 * 1_024
    static let defaultMaximumEntries = 6

    private let maximumEntryBytes: Int
    private let maximumStoredBytes: Int
    private let maximumEntries: Int
    private var entries: [UUID: Data] = [:]
    private var recency: [UUID] = []
    private var inFlight: [UUID: InFlightPreview] = [:]

    private struct InFlightPreview {
        let token: UUID
        let task: Task<Data?, Never>
    }

    init(
        maximumEntryBytes: Int = ArtifactPreviewCache.maximumEntryBytes,
        maximumStoredBytes: Int = ArtifactPreviewCache.defaultMaximumStoredBytes,
        maximumEntries: Int = ArtifactPreviewCache.defaultMaximumEntries
    ) {
        self.maximumEntryBytes = max(1, maximumEntryBytes)
        self.maximumStoredBytes = max(1, maximumStoredBytes)
        self.maximumEntries = max(1, maximumEntries)
    }

    func cachedData(for artifactID: UUID) -> Data? {
        guard let data = entries[artifactID] else { return nil }
        markMostRecent(artifactID)
        return data
    }

    func data(
        for artifactID: UUID,
        load: @escaping @Sendable () async -> Data?
    ) async -> Data? {
        if let cached = cachedData(for: artifactID) {
            return cached
        }
        if let pending = inFlight[artifactID] {
            return await pending.task.value
        }

        let pending = InFlightPreview(token: UUID(), task: Task { await load() })
        inFlight[artifactID] = pending
        let data = await pending.task.value
        if inFlight[artifactID]?.token == pending.token {
            inFlight[artifactID] = nil
        }
        guard let data, !data.isEmpty, data.count <= maximumEntryBytes else { return nil }
        store(data, for: artifactID)
        return data
    }

    /// Cancels stale neighbor work as the reader moves. The current Feed can
    /// therefore have no more than its configured adjacent-poster requests in
    /// flight, rather than accumulating fetches during a rapid swipe.
    func cancelInFlight(except artifactIDs: Set<UUID>) {
        let stale = inFlight.filter { !artifactIDs.contains($0.key) }
        for (artifactID, pending) in stale {
            pending.task.cancel()
            inFlight[artifactID] = nil
        }
    }

    private func store(_ data: Data, for artifactID: UUID) {
        entries[artifactID] = data
        markMostRecent(artifactID)
        while entries.count > maximumEntries || entries.values.reduce(0, { $0 + $1.count }) > maximumStoredBytes {
            guard let leastRecent = recency.first else { break }
            recency.removeFirst()
            entries[leastRecent] = nil
        }
    }

    private func markMostRecent(_ artifactID: UUID) {
        recency.removeAll { $0 == artifactID }
        recency.append(artifactID)
    }
}
