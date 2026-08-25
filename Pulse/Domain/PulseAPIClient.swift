import Foundation

struct PulseAPIError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

struct PulseAPIClient: Sendable {
    let baseURL: URL
    let viewer: String

    init(baseURL: URL? = nil, viewer: String = "you") {
        let configured = ProcessInfo.processInfo.environment["PULSE_API_BASE_URL"]
        self.baseURL = baseURL ?? configured.flatMap(URL.init(string:)) ?? URL(string: "http://localhost:8787/v1")!
        self.viewer = viewer
    }

    func artifactEntryURL(id: UUID) -> URL {
        baseURL.appending(path: "artifacts/\(id.pulsePathComponent)/files/index.html")
    }

    func resolveArtifactEntryURL(_ value: String, artifactID: UUID) -> URL? {
        let allowedDirectory = baseURL.appending(path: "artifacts/\(artifactID.pulsePathComponent)/files/")
        guard let resolved = URL(string: value, relativeTo: apiOrigin)?.absoluteURL,
              resolved.scheme == apiOrigin.scheme,
              resolved.host == apiOrigin.host,
              resolved.port == apiOrigin.port,
              resolved.path.hasPrefix(allowedDirectory.path)
        else { return nil }
        return resolved
    }

    func fetchFeed() async throws -> [InteractiveApp] {
        try await send(path: "feed", as: ListEnvelope<InteractiveApp>.self).data
    }

    func fetchMyWorks() async throws -> [InteractiveApp] {
        try await send(path: "me/works", as: ListEnvelope<InteractiveApp>.self).data
    }

    func setLike(workID: UUID, liked: Bool) async throws -> InteractiveApp {
        let response = try await send(path: "works/\(workID.pulsePathComponent)/like", method: liked ? "PUT" : "DELETE", as: WorkEnvelope.self)
        return response.work
    }

    func fetchComments(workID: UUID) async throws -> [AppComment] {
        try await send(path: "works/\(workID.pulsePathComponent)/comments", as: ListEnvelope<AppComment>.self).data
    }

    func comment(on workID: UUID, score: Int, body: String) async throws -> AppComment {
        let payload = CommentPayload(author: viewer, score: score, body: body)
        return try await send(path: "works/\(workID.pulsePathComponent)/comments", method: "POST", body: payload, as: CommentEnvelope.self).comment
    }

    func registerAsset(fileName: String, mediaType: String, sizeBytes: Int) async throws -> GenerationAsset {
        let payload = AssetPayload(fileName: fileName, mediaType: mediaType, sizeBytes: sizeBytes)
        let created = try await send(path: "assets/uploads", method: "POST", body: payload, as: AssetEnvelope.self).asset
        return try await send(path: "assets/uploads/\(created.id.pulsePathComponent)/complete", method: "POST", as: AssetEnvelope.self).asset
    }

    func createWork(instruction: String, parent: InteractiveApp?) async throws -> InteractiveApp {
        let mode: InteractiveApp.CreationMode = parent == nil ? .original : .remix
        let title = parent.map { "\($0.title) — Remix" } ?? String(instruction.prefix(28))
        let payload = CreateWorkPayload(
            title: title, instruction: instruction, theme: parent?.theme ?? "An AI-made interactive experience",
            tint: parent?.tint ?? "lime", interaction: parent?.interaction.rawValue ?? "garden",
            creationMode: mode, parentWorkID: parent?.id.pulsePathComponent
        )
        return try await send(path: "works", method: "POST", body: payload, idempotencyKey: UUID().uuidString, as: WorkEnvelope.self).work
    }

    func startGeneration(workID: UUID, instruction: String, assetIDs: [UUID]) async throws -> GenerationJob {
        let payload = CreateGenerationPayload(instruction: instruction, assetIds: assetIDs.map(\.pulsePathComponent))
        return try await send(path: "works/\(workID.pulsePathComponent)/generations", method: "POST", body: payload, idempotencyKey: UUID().uuidString, as: GenerationEnvelope.self).generation
    }

    func generation(id: UUID) async throws -> GenerationJob {
        try await send(path: "generations/\(id.pulsePathComponent)", as: GenerationEnvelope.self).generation
    }

    func plan(jobID: UUID) async throws -> GenerationPlan {
        try await send(path: "generations/\(jobID.pulsePathComponent)/plan", as: PlanEnvelope.self).plan
    }

    func publish(workID: UUID) async throws -> InteractiveApp {
        try await send(path: "works/\(workID.pulsePathComponent)/publish", method: "POST", as: WorkEnvelope.self).work
    }

    private func send<Response: Decodable>(path: String, method: String = "GET", idempotencyKey: String? = nil, as type: Response.Type) async throws -> Response {
        try await send(path: path, method: method, bodyData: nil, idempotencyKey: idempotencyKey, as: type)
    }

    private func send<Body: Encodable, Response: Decodable>(path: String, method: String, body: Body, idempotencyKey: String? = nil, as type: Response.Type) async throws -> Response {
        let bodyData = try JSONEncoder().encode(body)
        return try await send(path: path, method: method, bodyData: bodyData, idempotencyKey: idempotencyKey, as: type)
    }

    private func send<Response: Decodable>(path: String, method: String, bodyData: Data?, idempotencyKey: String?, as type: Response.Type) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(viewer, forHTTPHeaderField: "X-Pulse-User")
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw PulseAPIError(message: "Pulse API returned an invalid response.") }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
            throw PulseAPIError(message: envelope?.error.message ?? "Pulse API request failed (\(httpResponse.statusCode)).")
        }
        return try decoder.decode(type, from: data)
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let string = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid RFC 3339 timestamp")
        }
        return decoder
    }

    private var apiOrigin: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url!
    }
}

private struct ListEnvelope<Item: Decodable>: Decodable { let data: [Item] }
private struct WorkEnvelope: Decodable { let work: InteractiveApp }
private struct CommentEnvelope: Decodable { let comment: AppComment }
private struct AssetEnvelope: Decodable { let asset: GenerationAsset }
private struct GenerationEnvelope: Decodable { let generation: GenerationJob }
private struct PlanEnvelope: Decodable { let plan: GenerationPlan }
private struct ErrorEnvelope: Decodable { struct APIError: Decodable { let message: String }; let error: APIError }

private struct CommentPayload: Encodable { let author: String; let score: Int; let body: String }
private struct AssetPayload: Encodable { let fileName: String; let mediaType: String; let sizeBytes: Int }
private struct CreateGenerationPayload: Encodable { let instruction: String; let assetIds: [String] }
private struct CreateWorkPayload: Encodable {
    let title: String
    let instruction: String
    let theme: String
    let tint: String
    let interaction: String
    let creationMode: InteractiveApp.CreationMode
    let parentWorkID: String?

    enum CodingKeys: String, CodingKey {
        case title, instruction, theme, tint, interaction, creationMode
        case parentWorkID = "parentWorkId"
    }
}

private extension UUID {
    var pulsePathComponent: String { uuidString.lowercased() }
}
