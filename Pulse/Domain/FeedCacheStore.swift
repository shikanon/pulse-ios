import Foundation

/// A short-lived, public-only Feed snapshot. It lets the app preserve a useful
/// browsing surface while a transient network request is retried, without
/// treating a disk response as current server truth.
struct FeedCacheSnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let origin: String
    let savedAt: Date
    let data: [InteractiveApp]
    let nextCursor: String?
}

enum FeedDataSource: Equatable, Sendable {
    case none
    case live
    case cached(savedAt: Date)

    var cachedAt: Date? {
        guard case let .cached(savedAt) = self else { return nil }
        return savedAt
    }
}

struct FeedCacheStore: Sendable {
    static let maximumAge: TimeInterval = 15 * 60
    private static let maximumWorks = 50

    let fileURL: URL
    private let origin: String

    init(apiOrigin: URL? = nil, fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.origin = apiOrigin?.absoluteString ?? "default"
    }

    func load(now: Date = .now, maximumAge: TimeInterval = Self.maximumAge) -> FeedCacheSnapshot? {
        guard maximumAge > 0,
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? Self.decoder.decode(FeedCacheSnapshot.self, from: data),
              snapshot.schemaVersion == FeedCacheSnapshot.schemaVersion,
              snapshot.origin == origin,
              !snapshot.data.isEmpty
        else {
            remove()
            return nil
        }

        let age = now.timeIntervalSince(snapshot.savedAt)
        guard age >= -60, age <= maximumAge else {
            remove()
            return nil
        }
        return snapshot
    }

    func save(data: [InteractiveApp], nextCursor: String?, savedAt: Date = .now) {
        let deduplicated = data.reduce(into: [InteractiveApp]()) { result, work in
            guard !result.contains(where: { $0.id == work.id }) else { return }
            var publicWork = work
            // `viewerHasLiked` is account-specific. A public cache must never
            // leak that state to a later account on the same device.
            publicWork.isLiked = false
            result.append(publicWork)
        }
        guard !deduplicated.isEmpty else {
            remove()
            return
        }

        let snapshot = FeedCacheSnapshot(
            schemaVersion: FeedCacheSnapshot.schemaVersion,
            origin: origin,
            savedAt: savedAt,
            data: Array(deduplicated.prefix(Self.maximumWorks)),
            // A cursor after page 100 cannot be paired with a snapshot trimmed
            // to items 1–50. Dropping it forces the next online refresh to
            // start from a coherent first page instead of silently skipping
            // works 51–100.
            nextCursor: deduplicated.count > Self.maximumWorks ? nil : nextCursor
        )
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.encoder.encode(snapshot).write(to: fileURL, options: [.atomic])
        } catch {
            // A cache is best-effort. An unavailable or protected disk must not
            // alter online Feed behavior or surface an internal file-system error.
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static var defaultFileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appending(path: "Pulse", directoryHint: .isDirectory)
            .appending(path: "feed-cache-v1.json", directoryHint: .notDirectory)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
