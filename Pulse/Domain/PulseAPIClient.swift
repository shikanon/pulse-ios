import Foundation

/// XCUITest uses the development API's header authenticator so core account
/// journeys do not depend on a real Apple ID. The hook is compiled inert in
/// Release and additionally refuses every non-loopback API origin.
enum PulseLocalTestIdentity {
    static let environmentKey = "PULSE_UI_TEST_USER"

    static func username(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
#if DEBUG
        guard let rawValue = environment[environmentKey] else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard (3...30).contains(value.count), value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
#else
        return nil
#endif
    }

    static func apply(
        to request: inout URLRequest,
        apiURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
#if DEBUG
        guard apiURL.host == "localhost" || apiURL.host == "127.0.0.1",
              let username = username(environment: environment)
        else { return }
        request.setValue(username, forHTTPHeaderField: "X-Pulse-User")
#endif
    }
}

struct PulseValidationIssue: Decodable, Sendable, Hashable {
    let field: String
    let rule: String
}

struct PulseAPIError: LocalizedError, Sendable {
    let message: String
    let serverCode: String?
    let statusCode: Int?
    let validationIssues: [PulseValidationIssue]
    var errorDescription: String? { message }

    init(message: String) {
        self.message = message
        self.serverCode = nil
        self.statusCode = nil
        self.validationIssues = []
    }

    init(serverCode: String?, statusCode: Int, validationIssues: [PulseValidationIssue] = []) {
        self.message = PulseLocalization.apiError(code: serverCode, statusCode: statusCode)
        self.serverCode = serverCode
        self.statusCode = statusCode
        self.validationIssues = validationIssues
    }

    // Only locally-reviewed copy may reach a user. The server's field/rule
    // pair is deliberately used as a pointer back to a form control, never as
    // text to display or as a source of validation policy.
    func validationMessage(for fields: [String]) -> String? {
        guard serverCode == "validation_failed" else { return nil }
        for field in fields {
            guard let issue = validationIssues.first(where: { $0.field == field }),
                  let message = PulseLocalization.validationRule(issue.rule)
            else { continue }
            return message
        }
        return nil
    }

    func hasValidationIssue(for field: String) -> Bool {
        serverCode == "validation_failed" && validationIssues.contains { $0.field == field }
    }
}

struct PulseAPIClient: Sendable {
    let baseURL: URL
    let launchConfigurationError: String?
    private let urlSession: URLSession

    init(baseURL: URL? = nil, urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        if let baseURL {
            self.baseURL = baseURL
            self.launchConfigurationError = nil
            return
        }

#if DEBUG
        let configured = ProcessInfo.processInfo.environment["PULSE_API_BASE_URL"]
            ?? PulseEndpointConfiguration.bundledAPIBaseURL
            ?? "http://localhost:8787/v1"
        let allowsLocalDevelopment = true
#else
        let configured = PulseEndpointConfiguration.bundledAPIBaseURL
        let allowsLocalDevelopment = false
#endif

        if let resolved = PulseEndpointConfiguration.approvedAPIBaseURL(configured, allowsLocalDevelopment: allowsLocalDevelopment) {
            self.baseURL = resolved
            self.launchConfigurationError = nil
        } else {
            self.baseURL = PulseEndpointConfiguration.unavailableBaseURL
            self.launchConfigurationError = "This build does not contain an approved Pulse API origin. Update the Release configuration before distributing it."
        }
    }

    var isLocalDevelopmentServer: Bool {
        baseURL.host?.lowercased() == "localhost" || baseURL.host == "127.0.0.1"
    }

    var feedCacheOrigin: URL { apiOrigin }

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

    func fetchArtifactPreview(_ value: String, artifactID: UUID) async throws -> Data {
        guard let url = resolveArtifactPreviewURL(value, artifactID: artifactID) else {
            throw PulseAPIError(message: "Pulse could not prepare this static preview.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("image/png", forHTTPHeaderField: "Accept")
        PulseClientRuntimeDeclaration.apply(to: &request)
        attachAccessToken(to: &request)
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PulseAPIError(message: "Pulse could not load this static preview.")
        }
        if httpResponse.statusCode == 401, try await refreshStoredSession() {
            request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("image/png", forHTTPHeaderField: "Accept")
            PulseClientRuntimeDeclaration.apply(to: &request)
            attachAccessToken(to: &request)
            let (refreshedData, refreshedResponse) = try await urlSession.data(for: request)
            guard let refreshedHTTP = refreshedResponse as? HTTPURLResponse else {
                throw PulseAPIError(message: "Pulse could not load this static preview.")
            }
            return try validateArtifactPreview(data: refreshedData, response: refreshedHTTP)
        }
        return try validateArtifactPreview(data: data, response: httpResponse)
    }

    func resolveArtifactPreviewURL(_ value: String, artifactID: UUID) -> URL? {
        let expected = baseURL.appending(path: "artifacts/\(artifactID.pulsePathComponent)/files/preview.png")
        guard let resolved = URL(string: value, relativeTo: apiOrigin)?.absoluteURL,
              resolved.scheme == apiOrigin.scheme,
              resolved.host == apiOrigin.host,
              resolved.port == apiOrigin.port,
              resolved.path == expected.path,
              resolved.query == nil,
              resolved.fragment == nil
        else { return nil }
        return resolved
    }

    private func validateArtifactPreview(data: Data, response: HTTPURLResponse) throws -> Data {
        guard (200..<300).contains(response.statusCode),
              response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("image/png") == true,
              !data.isEmpty,
              data.count <= 1_048_576
        else {
            throw PulseAPIError(serverCode: nil, statusCode: response.statusCode)
        }
        return data
    }

    func fetchFeed() async throws -> [InteractiveApp] {
        try await fetchFeedPage().data
    }

    func fetchClientConfiguration() async throws -> PulseClientConfiguration {
        if let launchConfigurationError {
            throw PulseAPIError(message: launchConfigurationError)
        }
        return try await perform(
            makeRequest(path: "client-configuration", method: "GET", bodyData: nil, idempotencyKey: nil),
            as: ClientConfigurationEnvelope.self
        ).configuration
    }

    // This endpoint is intentionally unauthenticated. The event contract has
    // no account ID, token, work ID, or free text, and avoiding an access
    // token prevents telemetry from becoming an implicit identity channel.
    func recordClientTelemetry(events: [PulseTelemetryEvent]) async throws {
        guard !events.isEmpty, events.count <= PulseTelemetryPolicy.maximumBatchSize else { return }
        let payload = ClientTelemetryPayload(schemaVersion: PulseTelemetryPolicy.schemaVersion, events: events)
        try await sendUnauthenticatedNoContent(path: "client-events", method: "POST", body: payload)
    }

    func fetchFeedPage(cursor: String? = nil, limit: Int = 20) async throws -> FeedPage {
        var components = URLComponents(url: baseURL.appending(path: "feed"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))]
        if let cursor, !cursor.isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
        }
        guard let url = components?.url else { throw PulseAPIError(message: "Pulse could not prepare the feed request.") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        PulseClientRuntimeDeclaration.apply(to: &request)
        attachAccessToken(to: &request)
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw PulseAPIError(message: "Pulse API returned an invalid response.") }
        if httpResponse.statusCode == 401, try await refreshStoredSession() {
            request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            PulseClientRuntimeDeclaration.apply(to: &request)
            attachAccessToken(to: &request)
            return try await perform(request, as: FeedPage.self)
        }
        return try decode(data: data, response: httpResponse, as: FeedPage.self)
    }

    func fetchMyWorks() async throws -> [InteractiveApp] {
        try await send(path: "me/works", as: ListEnvelope<InteractiveApp>.self).data
    }

    func fetchMyReportsPage(cursor: String? = nil, limit: Int = 30) async throws -> ReporterReportPage {
        var components = URLComponents(url: baseURL.appending(path: "me/reports"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))]
        if let cursor, !cursor.isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
        }
        guard let url = components?.url else { throw PulseAPIError(message: "Pulse could not prepare your report history.") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        PulseClientRuntimeDeclaration.apply(to: &request)
        attachAccessToken(to: &request)
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw PulseAPIError(message: "Pulse API returned an invalid response.") }
        if httpResponse.statusCode == 401, try await refreshStoredSession() {
            request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            PulseClientRuntimeDeclaration.apply(to: &request)
            attachAccessToken(to: &request)
            return try await perform(request, as: ReporterReportPage.self)
        }
        return try decode(data: data, response: httpResponse, as: ReporterReportPage.self)
    }

    func fetchWork(id: UUID) async throws -> InteractiveApp {
        try await send(path: "works/\(id.pulsePathComponent)", as: WorkEnvelope.self).work
    }

    func fetchWorkVersions(workID: UUID) async throws -> [WorkVersion] {
        try await send(path: "works/\(workID.pulsePathComponent)/versions", as: ListEnvelope<WorkVersion>.self).data
    }

    func fetchPublicWork(slug: String) async throws -> InteractiveApp {
        try await send(path: "public/works/\(slug)", as: WorkEnvelope.self).work
    }

    func setLike(workID: UUID, liked: Bool) async throws -> InteractiveApp {
        let response = try await send(path: "works/\(workID.pulsePathComponent)/like", method: liked ? "PUT" : "DELETE", as: WorkEnvelope.self)
        return response.work
    }

    func fetchCommentsPage(workID: UUID, cursor: String? = nil, limit: Int = 30) async throws -> CommentPage {
        var components = URLComponents(url: baseURL.appending(path: "works/\(workID.pulsePathComponent)/comments"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))]
        if let cursor, !cursor.isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
        }
        guard let url = components?.url else { throw PulseAPIError(message: "Pulse could not prepare the comments request.") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        PulseClientRuntimeDeclaration.apply(to: &request)
        attachAccessToken(to: &request)
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw PulseAPIError(message: "Pulse API returned an invalid response.") }
        if httpResponse.statusCode == 401, try await refreshStoredSession() {
            request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            PulseClientRuntimeDeclaration.apply(to: &request)
            attachAccessToken(to: &request)
            return try await perform(request, as: CommentPage.self)
        }
        return try decode(data: data, response: httpResponse, as: CommentPage.self)
    }

    func comment(on workID: UUID, score: Int, body: String, idempotencyKey: String) async throws -> AppComment {
        let payload = CommentPayload(score: score, body: body)
        return try await send(
            path: "works/\(workID.pulsePathComponent)/comments",
            method: "POST",
            body: payload,
            idempotencyKey: idempotencyKey,
            as: CommentEnvelope.self
        ).comment
    }

    func deleteComment(workID: UUID, commentID: UUID) async throws {
        _ = try await sendNoContent(path: "works/\(workID.pulsePathComponent)/comments/\(commentID.pulsePathComponent)", method: "DELETE")
    }

    func report(targetType: String, targetID: String, reason: String, details: String) async throws -> ReporterReport {
        let payload = ReportPayload(targetType: targetType, targetId: targetID, reason: reason, details: details)
        return try await send(path: "reports", method: "POST", body: payload, idempotencyKey: UUID().uuidString, as: ReporterReportEnvelope.self).report
    }

    func block(username: String) async throws {
        _ = try await sendNoContent(path: "users/\(username)/block", method: "POST")
    }

    func unblock(username: String) async throws {
        _ = try await sendNoContent(path: "users/\(username)/block", method: "DELETE")
    }

    func blockedUsers() async throws -> [String] {
        try await send(path: "me/blocked-users", as: ListEnvelope<String>.self).data
    }

    func currentUser() async throws -> PulseUser {
        try await send(path: "me", as: UserEnvelope.self).user
    }

    func updateProfile(username: String, displayName: String) async throws -> PulseUser {
        try await send(path: "me", method: "PATCH", body: ProfilePayload(username: username, displayName: displayName), as: UserEnvelope.self).user
    }

    func acceptTerms() async throws -> PulseUser {
        try await send(path: "me/terms-acceptance", method: "POST", as: UserEnvelope.self).user
    }

    func exportAccountData() async throws -> AccountDataExport {
        try await send(path: "me/export", as: AccountExportEnvelope.self).export
    }

    func deleteAccount(confirmation: String, authorization: AppleDeletionAuthorization, idempotencyKey: String) async throws {
        let payload = AccountDeletionPayload(
            confirmation: confirmation,
            identityToken: authorization.identityToken,
            nonce: authorization.nonce,
            authorizationCode: authorization.authorizationCode
        )
        do {
            _ = try await sendNoContent(path: "me", method: "DELETE", body: payload, idempotencyKey: idempotencyKey)
        } catch {
            if (try? await accountDeletionCompleted(idempotencyKey: idempotencyKey)) == true {
                return
            }
            throw error
        }
    }

    func signInWithApple(identityToken: String, nonce: String, displayName: String?) async throws -> PulseAuthentication {
        let payload = AppleSignInPayload(identityToken: identityToken, nonce: nonce, username: nil, displayName: displayName)
        let authentication = try await sendUnauthenticated(path: "auth/apple", method: "POST", body: payload, as: PulseAuthentication.self)
        try PulseCredentialStore.save(authentication.session)
        return authentication
    }

    func signOut() async throws {
        var request = makeRequest(path: "auth/logout", method: "POST", bodyData: nil, idempotencyKey: nil)
        attachAccessToken(to: &request)
        let (_, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw PulseAPIError(message: "Pulse could not sign you out right now.")
        }
    }

    func registerAsset(fileName: String, mediaType: String, data: Data) async throws -> GenerationAsset {
        try await registerAssetWithProgress(fileName: fileName, mediaType: mediaType, data: data, recoveryContext: nil) { _ in }
    }

    func registerAssetWithProgress(
        fileName: String,
        mediaType: String,
        data: Data,
        recoveryContext: AssetUploadRecoveryContext?,
        progress: @escaping @MainActor @Sendable (AssetUploadProgress) -> Void
    ) async throws -> GenerationAsset {
        if let message = PrivateAssetUploadPolicy.validationMessage(fileName: fileName, mediaType: mediaType, sizeBytes: data.count) {
            throw PulseAPIError(message: message)
        }
        await progress(AssetUploadProgress(assetID: nil, phase: .preparing))
        var prepared: AssetUploadEnvelope?
        do {
            let payload = AssetPayload(fileName: fileName, mediaType: mediaType, sizeBytes: data.count)
            let uploadSession = try await send(path: "assets/uploads", method: "POST", body: payload, as: AssetUploadEnvelope.self)
            prepared = uploadSession
            await progress(AssetUploadProgress(assetID: uploadSession.asset.id, phase: .uploading(progress: 0)))
            try await upload(data: data, with: uploadSession, recoveryContext: recoveryContext, progress: { value in
                progress(AssetUploadProgress(assetID: uploadSession.asset.id, phase: .uploading(progress: value)))
            })
            await progress(AssetUploadProgress(assetID: uploadSession.asset.id, phase: .verifying))
            let asset = try await send(path: "assets/uploads/\(uploadSession.asset.id.pulsePathComponent)/complete", method: "POST", as: AssetEnvelope.self).asset
            BackgroundAssetUploadCoordinator.shared.discard(assetID: uploadSession.asset.id)
            await progress(AssetUploadProgress(assetID: asset.id, phase: .completed))
            return asset
        } catch {
            let uploadID = prepared?.asset.id
            // A failed background URLSession task retains its protected source
            // file and opaque upload record. Do not eagerly cancel that server
            // placeholder: the composer first probes completion for an
            // unknown-success race, then re-uploads only if OSS confirms the
            // object is absent. All non-background failures keep the existing
            // delete-and-reselect behavior.
            let preservesBackgroundRecovery = uploadID.flatMap { BackgroundAssetUploadStore.record(assetID: $0) } != nil
            if let uploadID, !AssetUploadRetryPolicy.preservesUploadedObject(for: error), !preservesBackgroundRecovery {
                BackgroundAssetUploadCoordinator.shared.cancelAndDiscard(assetID: uploadID)
                Task.detached(priority: .utility) { [self] in
                    // The server only accepts this for the uploading state. A
                    // completion race is harmless and leaves a ready asset intact.
                    // A known content-safety outage is deliberately excluded:
                    // the already-uploaded bytes remain server-side so the
                    // composer can retry completion without transferring them.
                    try? await cancelAssetUpload(id: uploadID)
                }
            }
            if error is CancellationError {
                await progress(AssetUploadProgress(assetID: uploadID, phase: .cancelled))
                throw CancellationError()
            }
            throw error
        }
    }

    func cancelAssetUpload(id: UUID) async throws {
        BackgroundAssetUploadCoordinator.shared.cancelAndDiscard(assetID: id)
        _ = try await sendNoContent(path: "assets/uploads/\(id.pulsePathComponent)", method: "DELETE")
    }

    func completeAssetUpload(
        id: UUID,
        progress: @escaping @MainActor @Sendable (AssetUploadProgress) -> Void
    ) async throws -> GenerationAsset {
        await progress(AssetUploadProgress(assetID: id, phase: .verifying))
        do {
            let asset = try await send(path: "assets/uploads/\(id.pulsePathComponent)/complete", method: "POST", as: AssetEnvelope.self).asset
            BackgroundAssetUploadCoordinator.shared.discard(assetID: id)
            await progress(AssetUploadProgress(assetID: asset.id, phase: .completed))
            return asset
        } catch is CancellationError {
            BackgroundAssetUploadCoordinator.shared.cancelAndDiscard(assetID: id)
            Task.detached(priority: .utility) { [self] in
                try? await cancelAssetUpload(id: id)
            }
            await progress(AssetUploadProgress(assetID: id, phase: .cancelled))
            throw CancellationError()
        }
    }

    func resumeBackgroundAssetUpload(
        _ record: BackgroundAssetUploadRecord,
        progress: @escaping @MainActor @Sendable (AssetUploadProgress) -> Void
    ) async throws -> GenerationAsset {
        try await BackgroundAssetUploadCoordinator.shared.resume(record) { value in
            progress(AssetUploadProgress(assetID: record.assetID, phase: .uploading(progress: value)))
        }
        return try await completeAssetUpload(id: record.assetID, progress: progress)
    }

    private func upload(
        data: Data,
        with session: AssetUploadEnvelope,
        recoveryContext: AssetUploadRecoveryContext?,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        guard let upload = session.upload else {
            guard session.uploadMode == "metadata-only-local" else {
                throw PulseAPIError(message: "Pulse API did not return an upload grant.")
            }
            await progress(1)
            return
        }
        guard upload.method == "PUT", let url = URL(string: upload.url), isAllowedUploadURL(url) else {
            throw PulseAPIError(message: "Pulse API returned an unsafe upload grant.")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = upload.method
        upload.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let context = recoveryContext ?? AssetUploadRecoveryContext(ownerID: "unscoped", parentWorkID: nil)
        try await BackgroundAssetUploadCoordinator.shared.upload(
            data: data,
            assetID: session.asset.id,
            context: context,
            fileName: session.asset.displayName,
            mediaType: session.asset.mediaType,
            request: request,
            progress: progress
        )
    }

    private func isAllowedUploadURL(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        return url.scheme?.lowercased() == "http" && isLocalDevelopmentServer && (url.host == "localhost" || url.host == "127.0.0.1")
    }

    func fetchAssetLibrary() async throws -> [GenerationAsset] {
        try await send(path: "assets/library", as: ListEnvelope<GenerationAsset>.self).data
    }

    func createWork(
        instruction: String,
        parent: InteractiveApp?,
        parentWorkID: UUID? = nil,
        allowRemix: Bool = CreationPreferences.defaultAllowRemix,
        idempotencyKey: String = UUID().uuidString
    ) async throws -> InteractiveApp {
        let remixParentID = parent?.id ?? parentWorkID
        let mode: InteractiveApp.CreationMode = remixParentID == nil ? .original : .remix
        let title = parent.map { "\($0.title) — Remix" } ?? String(instruction.prefix(28))
        let payload = CreateWorkPayload(
            title: title, instruction: instruction, theme: parent?.theme ?? "An AI-made interactive experience",
            tint: parent?.tint ?? "lime", interaction: parent?.interaction.rawValue ?? "garden",
            creationMode: mode, parentWorkID: remixParentID?.pulsePathComponent, allowRemix: allowRemix
        )
        return try await send(path: "works", method: "POST", body: payload, idempotencyKey: idempotencyKey, as: WorkEnvelope.self).work
    }

    func updateRemixPermission(workID: UUID, allowRemix: Bool) async throws -> InteractiveApp {
        try await send(
            path: "works/\(workID.pulsePathComponent)/remix-permission",
            method: "PATCH",
            body: UpdateWorkRemixPermissionPayload(allowRemix: allowRemix),
            as: WorkEnvelope.self
        ).work
    }

    func startGeneration(workID: UUID, instruction: String, assetIDs: [UUID], idempotencyKey: String = UUID().uuidString) async throws -> GenerationJob {
        let payload = CreateGenerationPayload(instruction: instruction, assetIds: assetIDs.map(\.pulsePathComponent))
        return try await send(path: "works/\(workID.pulsePathComponent)/generations", method: "POST", body: payload, idempotencyKey: idempotencyKey, as: GenerationEnvelope.self).generation
    }

    func generation(id: UUID) async throws -> GenerationJob {
        try await send(path: "generations/\(id.pulsePathComponent)", as: GenerationEnvelope.self).generation
    }

    func cancelGeneration(id: UUID) async throws -> GenerationJob {
        try await send(path: "generations/\(id.pulsePathComponent)/cancel", method: "POST", as: GenerationEnvelope.self).generation
    }

    func retryGeneration(id: UUID) async throws -> GenerationJob {
        try await send(
            path: "generations/\(id.pulsePathComponent)/retry",
            method: "POST",
            idempotencyKey: "retry-\(id.pulsePathComponent)",
            as: GenerationEnvelope.self
        ).generation
    }

    func plan(jobID: UUID) async throws -> GenerationPlan {
        try await send(path: "generations/\(jobID.pulsePathComponent)/plan", as: PlanEnvelope.self).plan
    }

    func verification(id: UUID) async throws -> VerificationReport {
        try await send(path: "verifications/\(id.pulsePathComponent)", as: VerificationEnvelope.self).verification
    }

    func publish(workID: UUID) async throws -> InteractiveApp {
        try await send(path: "works/\(workID.pulsePathComponent)/publish", method: "POST", as: WorkEnvelope.self).work
    }

    func unpublish(workID: UUID) async throws -> InteractiveApp {
        try await send(path: "works/\(workID.pulsePathComponent)/unpublish", method: "POST", as: WorkEnvelope.self).work
    }

    func requestContentReview(workID: UUID) async throws -> InteractiveApp {
        try await send(path: "works/\(workID.pulsePathComponent)/content-review-requests", method: "POST", as: WorkEnvelope.self).work
    }

    private func send<Response: Decodable>(path: String, method: String = "GET", idempotencyKey: String? = nil, as type: Response.Type) async throws -> Response {
        try await send(path: path, method: method, bodyData: nil, idempotencyKey: idempotencyKey, as: type)
    }

    private func send<Body: Encodable, Response: Decodable>(path: String, method: String, body: Body, idempotencyKey: String? = nil, as type: Response.Type) async throws -> Response {
        let bodyData = try JSONEncoder().encode(body)
        return try await send(path: path, method: method, bodyData: bodyData, idempotencyKey: idempotencyKey, as: type)
    }

    private func send<Response: Decodable>(path: String, method: String, bodyData: Data?, idempotencyKey: String?, as type: Response.Type) async throws -> Response {
        var request = makeRequest(path: path, method: method, bodyData: bodyData, idempotencyKey: idempotencyKey)
        attachAccessToken(to: &request)
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw PulseAPIError(message: "Pulse API returned an invalid response.") }
        if httpResponse.statusCode == 401, try await refreshStoredSession() {
            request = makeRequest(path: path, method: method, bodyData: bodyData, idempotencyKey: idempotencyKey)
            attachAccessToken(to: &request)
            return try await perform(request, as: type)
        }
        return try decode(data: data, response: httpResponse, as: type)
    }

    private func sendUnauthenticated<Body: Encodable, Response: Decodable>(path: String, method: String, body: Body, as type: Response.Type) async throws -> Response {
        let bodyData = try JSONEncoder().encode(body)
        return try await perform(makeRequest(path: path, method: method, bodyData: bodyData, idempotencyKey: nil), as: type)
    }

    private func sendNoContent<Body: Encodable>(path: String, method: String, body: Body, idempotencyKey: String? = nil) async throws -> Bool {
        try await sendNoContent(path: path, method: method, bodyData: try JSONEncoder().encode(body), idempotencyKey: idempotencyKey)
    }

    private func sendUnauthenticatedNoContent<Body: Encodable>(path: String, method: String, body: Body) async throws {
        let bodyData = try JSONEncoder().encode(body)
        let request = makeRequest(path: path, method: method, bodyData: bodyData, idempotencyKey: nil)
        let (_, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw PulseAPIError(message: "Pulse could not send diagnostics right now.")
        }
    }

    private func sendNoContent(path: String, method: String, bodyData: Data? = nil, idempotencyKey: String? = nil) async throws -> Bool {
        var request = makeRequest(path: path, method: method, bodyData: bodyData, idempotencyKey: idempotencyKey)
        attachAccessToken(to: &request)
        let (_, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PulseAPIError(message: "Pulse API returned an invalid response.")
        }
        if httpResponse.statusCode == 401, try await refreshStoredSession() {
            request = makeRequest(path: path, method: method, bodyData: bodyData, idempotencyKey: idempotencyKey)
            attachAccessToken(to: &request)
            let (_, refreshedResponse) = try await urlSession.data(for: request)
            guard let refreshedHTTP = refreshedResponse as? HTTPURLResponse, (200..<300).contains(refreshedHTTP.statusCode) else {
                throw PulseAPIError(message: "Pulse could not complete that action.")
            }
            return true
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw PulseAPIError(message: "Pulse could not complete that action.")
        }
        return true
    }

    private func accountDeletionCompleted(idempotencyKey: String) async throws -> Bool {
        let request = makeRequest(path: "account-deletion-status", method: "GET", bodyData: nil, idempotencyKey: idempotencyKey)
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PulseAPIError(message: "Pulse API returned an invalid response.")
        }
        if httpResponse.statusCode == 404 { return false }
        return try decode(data: data, response: httpResponse, as: AccountDeletionStatusEnvelope.self).deleted
    }

    private func perform<Response: Decodable>(_ request: URLRequest, as type: Response.Type) async throws -> Response {
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw PulseAPIError(message: "Pulse API returned an invalid response.") }
        return try decode(data: data, response: httpResponse, as: type)
    }

    private func decode<Response: Decodable>(data: Data, response: HTTPURLResponse, as type: Response.Type) throws -> Response {
        guard (200..<300).contains(response.statusCode) else {
            let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
            throw PulseAPIError(
                serverCode: envelope?.error.code,
                statusCode: response.statusCode,
                validationIssues: envelope?.error.validationIssues ?? []
            )
        }
        return try decoder.decode(type, from: data)
    }

    private func makeRequest(path: String, method: String, bodyData: Data?, idempotencyKey: String?) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        PulseClientRuntimeDeclaration.apply(to: &request)
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }
        return request
    }

    private func attachAccessToken(to request: inout URLRequest) {
        PulseLocalTestIdentity.apply(to: &request, apiURL: baseURL)
        guard let session = PulseCredentialStore.load() else { return }
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
    }

    private func refreshStoredSession() async throws -> Bool {
        guard let session = PulseCredentialStore.load() else { return false }
        let payload = try JSONEncoder().encode(RefreshPayload(refreshToken: session.refreshToken))
        let request = makeRequest(path: "auth/refresh", method: "POST", bodyData: payload, idempotencyKey: nil)
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            PulseCredentialStore.clear()
            return false
        }
        let refreshed = try decoder.decode(RefreshEnvelope.self, from: data)
        try PulseCredentialStore.save(refreshed.session)
        return true
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

struct FeedPage: Decodable, Sendable { let data: [InteractiveApp]; let nextCursor: String? }
struct CommentPage: Decodable, Sendable { let data: [AppComment]; let nextCursor: String? }
struct ReporterReportPage: Decodable, Sendable { let data: [ReporterReport]; let nextCursor: String? }
struct ReporterReportEnvelope: Decodable, Sendable { let report: ReporterReport; let duplicate: Bool }
private struct ListEnvelope<Item: Decodable>: Decodable { let data: [Item] }
private struct UserEnvelope: Decodable { let user: PulseUser }
private struct AccountExportEnvelope: Decodable { let export: AccountDataExport }
private struct AccountDeletionStatusEnvelope: Decodable { let deleted: Bool }
private struct WorkEnvelope: Decodable { let work: InteractiveApp }
private struct CommentEnvelope: Decodable { let comment: AppComment }
private struct AssetEnvelope: Decodable { let asset: GenerationAsset }
private struct AssetUploadEnvelope: Decodable {
    struct Upload: Decodable { let method: String; let url: String; let headers: [String: String]; let expiresAt: Date }
    let asset: GenerationAsset
    let uploadMode: String
    let upload: Upload?
}
private struct GenerationEnvelope: Decodable { let generation: GenerationJob }
private struct PlanEnvelope: Decodable { let plan: GenerationPlan }
private struct VerificationEnvelope: Decodable { let verification: VerificationReport }
private struct ErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let code: String
        let validationIssues: [PulseValidationIssue]

        enum CodingKeys: String, CodingKey {
            case code, details
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try container.decode(String.self, forKey: .code)
            validationIssues = (try? container.decode([PulseValidationIssue].self, forKey: .details)) ?? []
        }
    }

    let error: APIError
}

private struct CommentPayload: Encodable { let score: Int; let body: String }
private struct ReportPayload: Encodable { let targetType: String; let targetId: String; let reason: String; let details: String }
private struct AppleSignInPayload: Encodable { let identityToken: String; let nonce: String; let username: String?; let displayName: String? }
private struct AccountDeletionPayload: Encodable { let confirmation: String; let identityToken: String; let nonce: String; let authorizationCode: String }
private struct RefreshPayload: Encodable { let refreshToken: String }
private struct ProfilePayload: Encodable { let username: String; let displayName: String }
private struct RefreshEnvelope: Decodable { let user: PulseUser; let session: PulseSession }
private struct ClientTelemetryPayload: Encodable { let schemaVersion: Int; let events: [PulseTelemetryEvent] }
private struct AssetPayload: Encodable { let fileName: String; let mediaType: String; let sizeBytes: Int }
private struct CreateGenerationPayload: Encodable { let instruction: String; let assetIds: [String] }
private struct UpdateWorkRemixPermissionPayload: Encodable { let allowRemix: Bool }
struct CreateWorkPayload: Encodable {
    let title: String
    let instruction: String
    let theme: String
    let tint: String
    let interaction: String
    let creationMode: InteractiveApp.CreationMode
    let parentWorkID: String?
    let allowRemix: Bool

    enum CodingKeys: String, CodingKey {
        case title, instruction, theme, tint, interaction, creationMode
        case parentWorkID = "parentWorkId"
        case allowRemix
    }
}

private extension UUID {
    var pulsePathComponent: String { uuidString.lowercased() }
}
