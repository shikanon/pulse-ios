import Foundation
import XCTest
@testable import Pulse

final class APIContractTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(PulseAppLanguage.english.rawValue, forKey: PulseAppLanguage.storageKey)
    }

    func testSupportedAppLanguagesAreStableAndDistinct() {
        XCTAssertEqual(PulseAppLanguage.allCases.map(\.rawValue), ["en", "zh-Hans"])
        XCTAssertEqual(PulseAppLanguage.english.locale.identifier, "en")
        XCTAssertEqual(PulseAppLanguage.simplifiedChinese.locale.identifier, "zh-Hans")
    }

    func testDynamicErrorCopyFollowsTheInAppLanguageChoice() {
        let previous = UserDefaults.standard.string(forKey: PulseAppLanguage.storageKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: PulseAppLanguage.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: PulseAppLanguage.storageKey)
            }
        }

        UserDefaults.standard.set(PulseAppLanguage.simplifiedChinese.rawValue, forKey: PulseAppLanguage.storageKey)
        XCTAssertEqual(PulseLocalization.apiError(code: "not_found", statusCode: 404), "此内容已不可用。")
        UserDefaults.standard.set(PulseAppLanguage.english.rawValue, forKey: PulseAppLanguage.storageKey)
        XCTAssertEqual(PulseLocalization.apiError(code: "not_found", statusCode: 404), "This item is no longer available.")
    }

    func testLocalUITestIdentityIsDebugOnlyAndLoopbackBound() throws {
        let environment = [PulseLocalTestIdentity.environmentKey: "Pulse.E2E"]
        var localRequest = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:18787/v1/feed")))
        PulseLocalTestIdentity.apply(
            to: &localRequest,
            apiURL: try XCTUnwrap(URL(string: "http://127.0.0.1:18787/v1")),
            environment: environment
        )
#if DEBUG
        XCTAssertEqual(localRequest.value(forHTTPHeaderField: "X-Pulse-User"), "pulse.e2e")
#else
        XCTAssertNil(localRequest.value(forHTTPHeaderField: "X-Pulse-User"))
#endif

        var remoteRequest = URLRequest(url: try XCTUnwrap(URL(string: "https://api.pulse.test/v1/feed")))
        PulseLocalTestIdentity.apply(
            to: &remoteRequest,
            apiURL: try XCTUnwrap(URL(string: "https://api.pulse.test/v1")),
            environment: environment
        )
        XCTAssertNil(remoteRequest.value(forHTTPHeaderField: "X-Pulse-User"))

        XCTAssertNil(PulseLocalTestIdentity.username(environment: [PulseLocalTestIdentity.environmentKey: "invalid user"]))
    }

    func testClientConfigurationCacheIsShortLivedAndBoundToTheAPIOrigin() {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "pulse-client-configuration-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let apiOrigin = URL(string: "https://api.pulse.test/v1")!
        let cache = ClientConfigurationCacheStore(apiOrigin: apiOrigin, fileURL: fileURL)
        let configuration = PulseClientConfiguration(
            maintenance: false,
            maintenanceMessage: nil,
            minimumIOSVersion: nil,
            minimumIOSBuild: nil,
            supportURL: "https://support.pulse.test/help",
            privacyPolicyURL: "https://pulse.test/privacy",
            appStoreURL: "https://apps.apple.com/app/id123"
        )
        let savedAt = Date(timeIntervalSinceReferenceDate: 1_000_000)

        cache.save(configuration, savedAt: savedAt)
        XCTAssertEqual(cache.load(now: savedAt)?.configuration, configuration)
        XCTAssertNil(cache.load(now: savedAt.addingTimeInterval(ClientConfigurationCacheStore.maximumAge + 1)))

        cache.save(configuration, savedAt: savedAt)
        let otherOrigin = ClientConfigurationCacheStore(
            apiOrigin: URL(string: "https://another.pulse.test/v1")!,
            fileURL: fileURL
        )
        XCTAssertNil(otherOrigin.load(now: savedAt))
    }

    @MainActor
    func testMemberActionResumptionWaitsForProfileAndTermsAcceptance() {
        let session = SessionModel(api: PulseAPIClient(baseURL: URL(string: "https://api.pulse.test")!))
        XCTAssertFalse(session.canPerformMemberActions)
        XCTAssertFalse(session.canResumeMemberActions)

        session.user = PulseUser(id: "user-1", username: "pulse", displayName: "Pulse", email: nil, role: "creator")
        session.needsProfileSetup = true
        XCTAssertTrue(session.canPerformMemberActions)
        XCTAssertFalse(session.canResumeMemberActions)

        session.needsProfileSetup = false
        XCTAssertTrue(session.canResumeMemberActions)

        let policy = PulseTermsPolicy(url: URL(string: "https://pulse.test/terms/v1")!, version: "v1")
        session.configureTermsAcceptance(policy)
        XCTAssertTrue(session.needsTermsAcceptance)
        XCTAssertFalse(session.canResumeMemberActions)

        session.user = PulseUser(
            id: "user-1", username: "pulse", displayName: "Pulse", email: nil, role: "creator",
            termsAcceptance: PulseTermsAcceptance(version: "v1", url: "https://pulse.test/terms/v1", acceptedAt: .now)
        )
        session.configureTermsAcceptance(policy)
        XCTAssertFalse(session.needsTermsAcceptance)
        XCTAssertTrue(session.canResumeMemberActions)
    }

    func testServerErrorCodesUseReviewedLocalizedCopyInsteadOfServerMessages() {
        XCTAssertEqual(
            PulseAPIError(serverCode: "business_rule_failed", statusCode: 422).localizedDescription,
            "This action is not available right now."
        )
        XCTAssertEqual(
            PulseAPIError(serverCode: "not_found", statusCode: 404).localizedDescription,
            "This item is no longer available."
        )
        XCTAssertEqual(
            PulseAPIError(serverCode: "generation_quota_reached", statusCode: 429).localizedDescription,
            "You already have a creation in progress. Wait for it to finish or cancel it before starting another."
        )
        XCTAssertEqual(
            PulseAPIError(serverCode: "content_policy_rejected", statusCode: 422).localizedDescription,
            "This can’t be submitted under Pulse community guidelines. Please revise it and try again."
        )
        XCTAssertEqual(
            PulseAPIError(serverCode: "content_safety_unavailable", statusCode: 503).localizedDescription,
            "Pulse can’t check this right now. Your changes are still here—please try again shortly."
        )
        XCTAssertEqual(
            PulseAPIError(serverCode: "unrecognized_internal_code", statusCode: 500).localizedDescription,
            "Something went wrong. Please try again."
        )
    }

    func testValidationErrorDecodesStableFieldRulesWithoutServerDiagnostics() async throws {
        FeedRefreshURLProtocol.reset()
        defer { FeedRefreshURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedRefreshURLProtocol.self]
        let client = PulseAPIClient(
            baseURL: try XCTUnwrap(URL(string: "https://api.pulse.test/v1")),
            urlSession: URLSession(configuration: configuration)
        )
        FeedRefreshURLProtocol.configureRaw(
            statusCode: 422,
            body: Data(#"{"error":{"code":"validation_failed","message":"internal English diagnostic","details":[{"field":"limit","rule":"out_of_range"}]}}"#.utf8)
        )

        do {
            _ = try await client.fetchFeed()
            XCTFail("Expected validation error")
        } catch let error as PulseAPIError {
            XCTAssertEqual(error.serverCode, "validation_failed")
            XCTAssertEqual(error.validationIssues, [PulseValidationIssue(field: "limit", rule: "out_of_range")])
            XCTAssertEqual(error.localizedDescription, "Check the details and try again.")
            XCTAssertFalse(error.localizedDescription.contains("diagnostic"))
        }
    }

    func testStructuredValidationIssuesAreKeptWithoutDisplayingServerDiagnostics() {
        let issues = [
            PulseValidationIssue(field: "instruction", rule: "required"),
            PulseValidationIssue(field: "parentWorkId", rule: "required")
        ]
        let error = PulseAPIError(serverCode: "validation_failed", statusCode: 422, validationIssues: issues)

        XCTAssertEqual(error.localizedDescription, "Check the details and try again.")
        XCTAssertEqual(error.validationIssues, issues)
        XCTAssertFalse(error.localizedDescription.contains("instruction"))
        XCTAssertFalse(error.localizedDescription.contains("parentWorkId"))
    }

    func testStructuredValidationIssueUsesOnlyLocalCorrectionCopyForMatchingFormField() {
        let error = PulseAPIError(
            serverCode: "validation_failed",
            statusCode: 422,
            validationIssues: [PulseValidationIssue(field: "body", rule: "too_long")]
        )

        XCTAssertEqual(error.validationMessage(for: ["body"]), "Shorten this entry and try again.")
        XCTAssertNil(error.validationMessage(for: ["instruction"]))
        XCTAssertTrue(error.hasValidationIssue(for: "body"))
        XCTAssertFalse(error.validationMessage(for: ["body"])?.contains("body") ?? false)
    }

    func testGenerationCapabilitiesIdentifyOnlyTheLivePipelineAsModelBacked() async throws {
        GenerationCapabilitiesURLProtocol.reset()
        defer { GenerationCapabilitiesURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GenerationCapabilitiesURLProtocol.self]
        let client = PulseAPIClient(
            baseURL: try XCTUnwrap(URL(string: "https://api.pulse.test/v1")),
            urlSession: URLSession(configuration: configuration)
        )

        GenerationCapabilitiesURLProtocol.responseBody = Data(#"{"mode":"live","modelBacked":true}"#.utf8)
        let live = try await client.fetchGenerationCapabilities()
        XCTAssertEqual(live.mode, .live)
        XCTAssertTrue(live.usesLiveModel)

        GenerationCapabilitiesURLProtocol.responseBody = Data(#"{"mode":"deterministic-local","modelBacked":false}"#.utf8)
        let local = try await client.fetchGenerationCapabilities()
        XCTAssertEqual(local.mode, .deterministicLocal)
        XCTAssertFalse(local.usesLiveModel)
        XCTAssertEqual(
            GenerationCapabilitiesURLProtocol.capturedPaths(),
            ["/v1/generation-capabilities", "/v1/generation-capabilities"]
        )
    }

    func testReporterHistoryUsesOnlySafeStatusCopy() {
        let received = ReporterReport(
            id: UUID(), targetType: "work", reason: "Unsafe behavior", status: "open",
            createdAt: .now, updatedAt: .now, resolvedAt: nil
        )
        XCTAssertEqual(received.statusTitle, "Received")
        XCTAssertEqual(received.statusDetail, "Pulse has received your report.")

        let completed = ReporterReport(
            id: UUID(), targetType: "comment", reason: "Harassment", status: "actioned",
            createdAt: .now, updatedAt: .now, resolvedAt: .now
        )
        XCTAssertEqual(completed.statusTitle, "Review complete")
        XCTAssertEqual(completed.statusDetail, "Pulse has completed its review.")
        XCTAssertFalse(completed.statusDetail.lowercased().contains("moderator"))
    }

    func testReportReceiptDecodesOnlyReporterSafeFields() throws {
        let reportID = UUID()
        let data = Data("""
        {
          "report": {
            "id": "\(reportID.uuidString)",
            "targetType": "work",
            "reason": "Unsafe behavior",
            "status": "investigating",
            "createdAt": "2026-08-27T00:00:00Z",
            "updatedAt": "2026-08-27T00:01:00Z",
            "reporter": "alice",
            "targetId": "private-work-id",
            "details": "Private reporter detail.",
            "assignee": "moderator",
            "resolution": "Private moderation note."
          },
          "duplicate": true
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let receipt = try decoder.decode(ReporterReportEnvelope.self, from: data)

        XCTAssertTrue(receipt.duplicate)
        XCTAssertEqual(receipt.report.id, reportID)
        XCTAssertEqual(receipt.report.status, "investigating")
        XCTAssertEqual(receipt.report.reason, "Unsafe behavior")
    }

    func testDeepLinkUnavailableMapsOnlyToSafeActionableStates() {
        XCTAssertEqual(DeepLinkUnavailable(error: PulseAPIError(serverCode: "not_found", statusCode: 404)), .removed)
        XCTAssertEqual(DeepLinkUnavailable(error: PulseAPIError(serverCode: "age_restricted", statusCode: 403)), .ageRestricted)
        XCTAssertEqual(DeepLinkUnavailable(error: PulseAPIError(serverCode: "artifact_incompatible", statusCode: 422)), .incompatible)
        XCTAssertEqual(DeepLinkUnavailable(error: PulseAPIError(serverCode: "feature_disabled", statusCode: 503)), .temporarilyUnavailable)
        XCTAssertEqual(DeepLinkUnavailable(error: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(DeepLinkUnavailable(error: PulseAPIError(message: "private implementation detail")), .unavailable)
    }

    func testArtifactUnavailableMapsFailuresToSafePlaybackStates() {
        XCTAssertEqual(ArtifactUnavailable(error: PulseAPIError(serverCode: "artifact_file_missing", statusCode: 404)), .removed)
        XCTAssertEqual(ArtifactUnavailable(error: PulseAPIError(serverCode: "age_restricted", statusCode: 403)), .restricted)
        XCTAssertEqual(ArtifactUnavailable(error: PulseAPIError(serverCode: "artifact_incompatible", statusCode: 422)), .incompatible)
        XCTAssertEqual(ArtifactUnavailable(error: PulseAPIError(serverCode: "artifact_storage_unavailable", statusCode: 503)), .temporarilyUnavailable)
        XCTAssertEqual(ArtifactUnavailable(error: URLError(.cannotConnectToHost)), .offline)
        XCTAssertEqual(ArtifactUnavailable(error: PulseAPIError(message: "internal implementation detail")), .unavailable)
        XCTAssertFalse(ArtifactUnavailable(error: PulseAPIError(message: "internal implementation detail")).detail.contains("internal"))
    }

    func testGenerationFailurePresentationNeverShowsOperationalCategory() {
        let safety = GenerationFailurePresentation(stage: .failed, errorCategory: "artifact_safety_check_failed")
        XCTAssertEqual(safety, .needsChanges)
        XCTAssertFalse(safety.title.contains("artifact"))
        XCTAssertFalse(safety.detail.contains("artifact_safety_check_failed"))

        let infrastructure = GenerationFailurePresentation(stage: .failed, errorCategory: "verifier_unavailable")
        XCTAssertEqual(infrastructure, .temporarilyUnavailable)
        XCTAssertFalse(infrastructure.detail.contains("verifier"))

        XCTAssertEqual(GenerationFailurePresentation(stage: .failed, errorCategory: "future_internal_category"), .unavailable)
        XCTAssertEqual(GenerationFailurePresentation(stage: .cancelled, errorCategory: "artifact_safety_check_failed"), .cancelled)
    }

    func testTelemetrySchemaAllowsOnlyControlledDimensions() throws {
        let sessionID = UUID(uuidString: "5c8cbb4f-5a38-4c6a-a09f-266158b5b9d0")!
        let event = try XCTUnwrap(PulseTelemetryPolicy.makeEvent(
            name: .generationSubmitted,
            sessionID: sessionID,
            attributes: ["screen_id": "create", "creation_mode": "original"],
            appVersion: "1.2.3",
            build: "42"
        ))
        XCTAssertEqual(event.eventVersion, 1)
        XCTAssertEqual(event.sessionID, sessionID.uuidString.lowercased())
        XCTAssertEqual(event.attributes, ["screen_id": "create", "creation_mode": "original"])

        let backgrounded = try XCTUnwrap(PulseTelemetryPolicy.makeEvent(
            name: .generationBackgrounded,
            sessionID: sessionID,
            attributes: ["screen_id": "create", "creation_mode": "remix"],
            appVersion: "1.2.3",
            build: "42"
        ))
        XCTAssertEqual(backgrounded.name, .generationBackgrounded)
        XCTAssertEqual(backgrounded.attributes, ["screen_id": "create", "creation_mode": "remix"])

        XCTAssertNil(PulseTelemetryPolicy.makeEvent(
            name: .generationSubmitted,
            sessionID: sessionID,
            attributes: ["screen_id": "create", "creation_mode": "original", "prompt": "never send this"],
            appVersion: "1.2.3",
            build: "42"
        ))
        XCTAssertNil(PulseTelemetryPolicy.makeEvent(
            name: .feedLoaded,
            sessionID: sessionID,
            attributes: ["screen_id": "feed"],
            appVersion: "1.2.3",
            build: "42"
        ))
    }

    @MainActor
    func testDiagnosticsPreferenceIsOffByDefaultAndCanBeWithdrawn() {
        let suiteName = "PulseTelemetryTests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let telemetry = PulseTelemetry(preferences: preferences)
        XCTAssertFalse(telemetry.isDiagnosticsSharingEnabled)
        telemetry.setDiagnosticsSharingEnabled(true)
        XCTAssertTrue(telemetry.isDiagnosticsSharingEnabled)
        telemetry.setDiagnosticsSharingEnabled(false)
        XCTAssertFalse(telemetry.isDiagnosticsSharingEnabled)
    }

    func testPrivateAssetUploadPolicyMatchesTheSupportedStorefrontContract() {
        XCTAssertNil(PrivateAssetUploadPolicy.validationMessage(fileName: "portrait.HEIC", mediaType: "IMAGE/HEIC", sizeBytes: 20_000_000))
        XCTAssertNil(PrivateAssetUploadPolicy.validationMessage(fileName: "loop.m4a", mediaType: "audio/mp4", sizeBytes: 128))
        XCTAssertNil(PrivateAssetUploadPolicy.validationMessage(fileName: "scene.webm", mediaType: "video/webm", sizeBytes: 128))

        XCTAssertNotNil(PrivateAssetUploadPolicy.validationMessage(fileName: "image.svg", mediaType: "image/svg+xml", sizeBytes: 128))
        XCTAssertNotNil(PrivateAssetUploadPolicy.validationMessage(fileName: "../private.mp3", mediaType: "audio/mpeg", sizeBytes: 128))
        XCTAssertNotNil(PrivateAssetUploadPolicy.validationMessage(fileName: "large.mp4", mediaType: "video/mp4", sizeBytes: 20_000_001))
        XCTAssertNotNil(PrivateAssetUploadPolicy.validationMessage(fileName: "bad\nname.mp3", mediaType: "audio/mpeg", sizeBytes: 128))
    }

    func testContentSafetyOutageKeepsAnUploadedAssetEligibleForCompletionRetry() {
        XCTAssertTrue(AssetUploadRetryPolicy.preservesUploadedObject(for: PulseAPIError(serverCode: "content_safety_unavailable", statusCode: 503)))
        XCTAssertFalse(AssetUploadRetryPolicy.preservesUploadedObject(for: PulseAPIError(serverCode: "content_policy_rejected", statusCode: 422)))
        XCTAssertFalse(AssetUploadRetryPolicy.preservesUploadedObject(for: PulseAPIError(message: "Network request failed")))
    }

    func testGenerationTerminalStagesKeepCancellationSeparateFromSuccessfulPreview() {
        XCTAssertFalse(GenerationJob.Stage.coding.isTerminal)
        XCTAssertTrue(GenerationJob.Stage.succeeded.isTerminal)
        XCTAssertTrue(GenerationJob.Stage.fallbackReady.isTerminal)
        XCTAssertTrue(GenerationJob.Stage.failed.isTerminal)
        XCTAssertTrue(GenerationJob.Stage.cancelled.isTerminal)
        XCTAssertEqual(GenerationJob.Stage.cancelled.productTitle, "Generation cancelled")
        XCTAssertEqual(GenerationJob.Stage.failed.productTitle, "Generation needs attention")
    }

    func testCelebrityTankBattleFixtureUsesOriginalCreationPromptAndBundledImages() throws {
        let prompt = "生成一个各种名人头像的坦克大战"
        let fileNames = ["abraham-lincoln", "nikola-tesla", "ada-lovelace", "william-shakespeare"]
        let fixtureBundle = Bundle(for: Self.self)

        XCTAssertFalse(prompt.isEmpty)
        XCTAssertEqual(Set(fileNames).count, 4)
        for fileName in fileNames {
            let url = try XCTUnwrap(fixtureBundle.url(forResource: fileName, withExtension: "jpg"), "Missing test fixture: \(fileName).jpg")
            XCTAssertGreaterThan(try Data(contentsOf: url).count, 10_000)
        }
    }

    func testGenerationJobDecodesGoIDKeysAndEmptyCollections() throws {
        let data = Data(#"""
        {
          "id":"8c92f064-fc35-4c91-a83e-f40e52ed89d3",
          "workId":"59bcc7cc-7363-4413-8b79-b700667f2dde",
          "runId":"f9a75473-b507-4e3c-b66a-8d56b796c0dc",
          "instruction":"Build a neon planet",
          "assetIds":[],
          "creationMode":"original",
          "stage":"succeeded",
          "statusMessage":"ready",
          "verificationGrade":"verified",
          "planId":"be4f0389-1009-4f57-86dc-b7e263c9874c",
          "artifactId":"30b86b66-7fd2-4cdc-9dc2-0733f4e64c25",
          "verificationId":"3327fcbc-d936-4279-a5ed-e6083d52a540",
          "retryable":false,
          "createdAt":"2026-08-20T08:09:06Z",
          "updatedAt":"2026-08-20T08:09:07Z",
          "terminalAt":"2026-08-20T08:09:07Z"
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let job = try decoder.decode(GenerationJob.self, from: data)

        XCTAssertEqual(job.workID.uuidString.lowercased(), "59bcc7cc-7363-4413-8b79-b700667f2dde")
        XCTAssertEqual(job.runID.uuidString.lowercased(), "f9a75473-b507-4e3c-b66a-8d56b796c0dc")
        XCTAssertTrue(job.assetIDs.isEmpty)
        XCTAssertEqual(job.planID?.uuidString.lowercased(), "be4f0389-1009-4f57-86dc-b7e263c9874c")
    }

    func testWorkVersionDecodesCreatorSafeGoKeys() throws {
        let data = Data(#"""
        {
          "version":2,
          "generationId":"8c92f064-fc35-4c91-a83e-f40e52ed89d3",
          "artifactId":"30b86b66-7fd2-4cdc-9dc2-0733f4e64c25",
          "verificationId":"3327fcbc-d936-4279-a5ed-e6083d52a540",
          "verificationGrade":"verified",
          "stage":"succeeded",
          "isCurrent":true,
          "isPublished":false,
          "createdAt":"2026-08-20T08:09:06Z"
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let version = try decoder.decode(WorkVersion.self, from: data)

        XCTAssertEqual(version.version, 2)
        XCTAssertEqual(version.generationID.uuidString.lowercased(), "8c92f064-fc35-4c91-a83e-f40e52ed89d3")
        XCTAssertEqual(version.stage, .succeeded)
        XCTAssertTrue(version.isCurrent)
        XCTAssertFalse(version.isPublished)
    }

    func testInteractionKindPreservesServerExtensions() throws {
        let interaction = try JSONDecoder().decode(InteractiveApp.InteractionKind.self, from: Data("\"touch-garden\"".utf8))
        XCTAssertEqual(interaction.rawValue, "touch-garden")
    }

    func testWorkDecodesOptionalLifecycleTimestampsForProfileFreshness() throws {
        let data = Data(#"""
        {
          "id":"59bcc7cc-7363-4413-8b79-b700667f2dde",
          "title":"Fresh private draft",
          "creator":"maya",
          "prompt":"Show when it changed",
          "theme":"garden",
          "tint":"lime",
          "interaction":"garden",
          "creationMode":"original",
          "rootWorkId":"59bcc7cc-7363-4413-8b79-b700667f2dde",
          "originalCreator":"maya",
          "allowRemix":true,
          "status":"draft",
          "verificationGrade":"verified",
          "contentReviewStatus":"pending",
          "ageRating":"unrated",
          "likes":0,
          "comments":0,
          "remixes":0,
          "viewerHasLiked":false,
          "currentVersion":3,
          "createdAt":"2026-08-20T08:09:06Z",
          "updatedAt":"2026-08-20T08:10:07Z"
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let work = try decoder.decode(InteractiveApp.self, from: data)

        XCTAssertEqual(work.createdAt, ISO8601DateFormatter().date(from: "2026-08-20T08:09:06Z"))
        XCTAssertEqual(work.updatedAt, ISO8601DateFormatter().date(from: "2026-08-20T08:10:07Z"))
        XCTAssertEqual(work.currentVersion, 3)
    }

    func testResourceLibraryDecodesPublicBGMAndLegacyPrivateAsset() throws {
        let publicData = Data(#"""
        {
          "id":"10000000-0000-4000-8000-000000000003",
          "owner":"pulse-official",
          "library":"public",
          "source":"official",
          "kind":"audio",
          "displayName":"Arcade Rush BGM",
          "fileName":"arcade-rush.mp3",
          "mediaType":"audio/mpeg",
          "sizeBytes":0,
          "status":"ready",
          "summary":"High-energy loop",
          "license":"Pulse Official",
          "deliveryUrl":"https://cdn.ai.lovetalk.chat/public/assets/v1/arcade-rush.mp3"
        }
        """#.utf8)
        let publicAsset = try JSONDecoder().decode(GenerationAsset.self, from: publicData)
        XCTAssertEqual(publicAsset.library, .public)
        XCTAssertEqual(publicAsset.source, .official)
        XCTAssertEqual(publicAsset.kind, .audio)
        XCTAssertEqual(publicAsset.iconName, "music.note")
        XCTAssertEqual(publicAsset.deliveryURL?.host, "cdn.ai.lovetalk.chat")

        let legacyData = Data(#"""
        {
          "id":"9a910ce7-b47a-45df-9ff7-84639a806865",
          "owner":"you",
          "fileName":"portrait.png",
          "mediaType":"image/png",
          "sizeBytes":128,
          "status":"ready"
        }
        """#.utf8)
        let legacyAsset = try JSONDecoder().decode(GenerationAsset.self, from: legacyData)
        XCTAssertEqual(legacyAsset.library, .private)
        XCTAssertEqual(legacyAsset.source, .upload)
        XCTAssertEqual(legacyAsset.kind, .image)
        XCTAssertEqual(legacyAsset.displayName, "portrait.png")
        XCTAssertNil(legacyAsset.deliveryURL)
    }

    func testPublishedWorkDecodesArtifactPlayerContract() throws {
        let data = Data(#"""
        {
          "id":"59bcc7cc-7363-4413-8b79-b700667f2dde",
          "title":"Neon Snake",
          "creator":"you",
          "prompt":"生成疯狂版本的贪吃蛇",
          "theme":"Hyper arcade",
          "tint":"lime",
          "interaction":"game",
          "creationMode":"original",
          "rootWorkId":"59bcc7cc-7363-4413-8b79-b700667f2dde",
          "originalCreator":"you",
          "allowRemix":true,
          "status":"published",
          "verificationGrade":"degraded",
          "contentReviewStatus":"pending",
          "ageRating":"unrated",
          "contentReviewRequestedAt":"2026-08-20T08:09:08Z",
          "generationJobId":"8c92f064-fc35-4c91-a83e-f40e52ed89d3",
          "artifactId":"30b86b66-7fd2-4cdc-9dc2-0733f4e64c25",
          "artifactEntryUrl":"/v1/artifacts/30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/files/index.html",
          "artifactPreviewUrl":"/v1/artifacts/30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/files/preview.png",
          "likes":0,
          "comments":0,
          "remixes":0,
          "viewerHasLiked":false
        }
        """#.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let work = try decoder.decode(InteractiveApp.self, from: data)

        XCTAssertEqual(work.artifactID?.uuidString.lowercased(), "30b86b66-7fd2-4cdc-9dc2-0733f4e64c25")
        XCTAssertEqual(work.artifactEntryURL, "/v1/artifacts/30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/files/index.html")
        XCTAssertEqual(work.artifactPreviewURL, "/v1/artifacts/30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/files/preview.png")
        XCTAssertEqual(work.contentReviewStatus, .pending)
        XCTAssertEqual(work.contentReviewRequestedAt, ISO8601DateFormatter().date(from: "2026-08-20T08:09:08Z"))
    }

    func testRevokedPublicLinkMarkerDecodesForCreatorLifecycleFiltering() throws {
        let data = Data(#"""
        {
          "id":"59bcc7cc-7363-4413-8b79-b700667f2dde",
          "title":"Private after revocation",
          "creator":"you",
          "prompt":"Keep this private",
          "theme":"Quiet review",
          "tint":"violet",
          "interaction":"garden",
          "creationMode":"original",
          "rootWorkId":"59bcc7cc-7363-4413-8b79-b700667f2dde",
          "originalCreator":"you",
          "allowRemix":true,
          "status":"draft",
          "verificationGrade":"verified",
          "contentReviewStatus":"approved",
          "ageRating":"4+",
          "publicLinkRevokedAt":"2026-08-20T08:09:08Z",
          "likes":0,
          "comments":0,
          "remixes":0,
          "viewerHasLiked":false
        }
        """#.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let work = try decoder.decode(InteractiveApp.self, from: data)

        XCTAssertEqual(work.status, .draft)
        XCTAssertEqual(work.publicLinkRevokedAt, ISO8601DateFormatter().date(from: "2026-08-20T08:09:08Z"))
    }

    func testArtifactURLResolutionStaysOnAPIOrigin() throws {
        let client = PulseAPIClient(baseURL: try XCTUnwrap(URL(string: "http://localhost:8787/v1")))
        let relative = "/v1/artifacts/30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/files/index.html"

        let artifactID = try XCTUnwrap(UUID(uuidString: "30b86b66-7fd2-4cdc-9dc2-0733f4e64c25"))
        XCTAssertEqual(client.resolveArtifactEntryURL(relative, artifactID: artifactID)?.absoluteString, "http://localhost:8787/v1/artifacts/30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/files/index.html")
        XCTAssertNil(client.resolveArtifactEntryURL("https://attacker.example/game.html", artifactID: artifactID))
        XCTAssertNil(client.resolveArtifactEntryURL("/v1/feed", artifactID: artifactID))
    }

    func testArtifactPreviewURLResolutionAllowsOnlyTheBoundRendererPoster() throws {
        let client = PulseAPIClient(baseURL: try XCTUnwrap(URL(string: "https://api.pulse.test/v1")))
        let artifactID = try XCTUnwrap(UUID(uuidString: "30b86b66-7fd2-4cdc-9dc2-0733f4e64c25"))
        let preview = "/v1/artifacts/30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/files/preview.png"

        XCTAssertEqual(client.resolveArtifactPreviewURL(preview, artifactID: artifactID)?.absoluteString, "https://api.pulse.test/v1/artifacts/30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/files/preview.png")
        XCTAssertNil(client.resolveArtifactPreviewURL("/v1/artifacts/30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/files/index.html", artifactID: artifactID))
        XCTAssertNil(client.resolveArtifactPreviewURL("https://attacker.example/preview.png", artifactID: artifactID))
        XCTAssertNil(client.resolveArtifactPreviewURL(preview + "?token=not-allowed", artifactID: artifactID))
    }

    func testFeedPreviewCacheDeduplicatesFetchesAndEnforcesItsMemoryBudget() async {
        let artifactID = UUID()
        let cache = ArtifactPreviewCache(maximumEntryBytes: 8, maximumStoredBytes: 12, maximumEntries: 2)
        let counter = PreviewLoadCounter()
        let preview = Data(repeating: 7, count: 8)

        async let first: Data? = cache.data(for: artifactID) {
            await counter.load(preview)
        }
        async let second: Data? = cache.data(for: artifactID) {
            await counter.load(preview)
        }
        let results = await (first, second)
        XCTAssertEqual(results.0, preview)
        XCTAssertEqual(results.1, preview)
        let loadCount = await counter.count
        XCTAssertEqual(loadCount, 1)

        let newerArtifactID = UUID()
        let newerPreview = Data(repeating: 3, count: 8)
        let cachedNewer = await cache.data(for: newerArtifactID) { newerPreview }
        XCTAssertEqual(cachedNewer, newerPreview)
        let evicted = await cache.cachedData(for: artifactID)
        XCTAssertNil(evicted, "the 12-byte budget must evict the least-recent poster")

        let oversizedArtifactID = UUID()
        let oversized = await cache.data(for: oversizedArtifactID) { Data(repeating: 0, count: 9) }
        XCTAssertNil(oversized, "a renderer poster over the per-image limit is never retained")
    }

    @MainActor
    func testFeedPreviewCacheDoesNotReusePosterWhenServerOmitsItsURL() async throws {
        let artifactID = UUID()
        let cache = ArtifactPreviewCache()
        let preview = Data(repeating: 4, count: 12)
        _ = await cache.data(for: artifactID) { preview }

        let api = PulseAPIClient(baseURL: try XCTUnwrap(URL(string: "https://api.pulse.test/v1")))
        let model = AppModel(api: api, feedPreviewCache: cache)
        let workWithoutPreview = InteractiveApp(
            title: "No retained poster",
            creator: "pulse",
            prompt: "A safe Feed item",
            theme: "calm",
            tint: "lime",
            likes: 0,
            comments: 0,
            remixes: 0,
            interaction: .garden,
            artifactID: artifactID
        )
        let omittedPreview = await model.cachedFeedPreviewData(for: workWithoutPreview)
        XCTAssertNil(omittedPreview)

        let workWithPreview = InteractiveApp(
            title: "Authorized poster",
            creator: "pulse",
            prompt: "A safe Feed item",
            theme: "calm",
            tint: "lime",
            likes: 0,
            comments: 0,
            remixes: 0,
            interaction: .garden,
            artifactID: artifactID,
            artifactPreviewURL: "/v1/artifacts/\(artifactID.uuidString.lowercased())/files/preview.png"
        )
        let authorizedPreview = await model.cachedFeedPreviewData(for: workWithPreview)
        XCTAssertEqual(authorizedPreview, preview)
    }

    func testArtifactRuntimeSourceScopesEveryBundleRequestToOneArtifact() throws {
        let entry = try XCTUnwrap(URL(string: "https://api.pulse.example/v1/artifacts/30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/files/index.html"))
        let source = try XCTUnwrap(ArtifactRuntimeSource(apiEntryURL: entry))

        XCTAssertEqual(source.entryURL.absoluteString, "pulse-artifact://30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/index.html")
        XCTAssertEqual(
            source.apiURL(for: source.entryURL)?.absoluteString,
            "https://api.pulse.example/v1/artifacts/30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/files/index.html"
        )
        XCTAssertNil(source.apiURL(for: try XCTUnwrap(URL(string: "pulse-artifact://another-artifact/index.html"))))
        XCTAssertNil(source.apiURL(for: try XCTUnwrap(URL(string: "pulse-artifact://30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/index.html?token=secret"))))
        XCTAssertNil(ArtifactRuntimeSource(apiEntryURL: try XCTUnwrap(URL(string: "http://api.pulse.example/v1/artifacts/30b86b66-7fd2-4cdc-9dc2-0733f4e64c25/files/index.html"))))
    }

    func testRuntimeMotionPolicyHonorsInactiveSurfacesAndReduceMotion() {
        XCTAssertTrue(PulseAccessibility.runtimeIsActive(isVisible: true, isApplicationActive: true))
        XCTAssertFalse(PulseAccessibility.runtimeIsActive(isVisible: false, isApplicationActive: true))
        XCTAssertFalse(PulseAccessibility.runtimeIsActive(isVisible: true, isApplicationActive: false))
        XCTAssertFalse(PulseAccessibility.runtimeIsActive(isVisible: true, isApplicationActive: true, isObscured: true))
        XCTAssertFalse(PulseAccessibility.runtimeIsActive(isVisible: true, isApplicationActive: true, isSystemRuntimeAvailable: false))
        XCTAssertEqual(
            PulseAccessibility.runtimeMotionState(isActive: true, reduceMotion: false),
            .active
        )
        XCTAssertEqual(
            PulseAccessibility.runtimeMotionState(isActive: false, reduceMotion: false),
            .pausedForInactiveSurface
        )
        XCTAssertEqual(
            PulseAccessibility.runtimeMotionState(isActive: true, reduceMotion: true),
            .pausedForReducedMotion
        )

        let reducedMotionScript = PulseAccessibility.runtimeScript(for: .pausedForReducedMotion)
        XCTAssertTrue(reducedMotionScript.contains("pulse:motion-preference"))
        XCTAssertTrue(reducedMotionScript.contains("pulse:pause"))
        XCTAssertTrue(reducedMotionScript.contains("pulse-reduced-motion-style"))
        XCTAssertFalse(PulseAccessibility.runtimeScript(for: .active).contains("element.play"))
        XCTAssertTrue(PulseAccessibility.interactiveSummary(title: "Night Signals", theme: "A constellation that remembers").contains("Night Signals"))
    }

    @MainActor
    func testRuntimeLifecycleStopsForAudioInterruptionAndMemoryWarning() {
        let lifecycle = PulseRuntimeLifecycle(observesSystemNotifications: false)
        XCTAssertTrue(lifecycle.allowsRuntime)

        lifecycle.noteAudioInterruptionBegan()
        XCTAssertFalse(lifecycle.allowsRuntime)
        lifecycle.noteAudioInterruptionEnded()
        XCTAssertTrue(lifecycle.allowsRuntime)

        lifecycle.noteMemoryWarning()
        XCTAssertFalse(lifecycle.allowsRuntime)
        lifecycle.update(scenePhase: .active)
        XCTAssertFalse(lifecycle.allowsRuntime)
        lifecycle.update(scenePhase: .inactive)
        lifecycle.update(scenePhase: .active)
        XCTAssertTrue(lifecycle.allowsRuntime)
    }

    func testClientLaunchConfigurationEnforcesVersionAndBuildWithoutTreatingInvalidVersionsAsUpdates() throws {
        let configuration = try JSONDecoder().decode(PulseClientConfiguration.self, from: Data(#"""
        {
          "maintenance": false,
          "minimumIOSVersion": "1.2.0",
          "minimumIOSBuild": 42,
          "supportURL": "https://support.pulse.example",
          "privacyPolicyURL": "https://pulse.example/privacy",
          "termsURL": "https://pulse.example/terms/v1",
          "termsVersion": "2026-08-28",
          "appStoreURL": "https://apps.apple.com/app/id123"
        }
        """#.utf8))

        XCTAssertTrue(configuration.requiresUpdate(for: PulseAppVersion(marketingVersion: "1.1.9", buildNumber: 99)))
        XCTAssertTrue(configuration.requiresUpdate(for: PulseAppVersion(marketingVersion: "1.2.0", buildNumber: 41)))
        XCTAssertFalse(configuration.requiresUpdate(for: PulseAppVersion(marketingVersion: "1.2.0", buildNumber: 42)))
        XCTAssertEqual(PulseAppVersion.compare("1.2", "1.2.0"), .orderedSame)
        XCTAssertNil(PulseAppVersion.compare("1.2-beta", "1.2.0"))
        XCTAssertEqual(PulseAppVersion(marketingVersion: "1.2.3", buildNumber: 42).displayLabel, "Version 1.2.3 (42)")
        XCTAssertEqual(configuration.resolvedSupportURL?.host, "support.pulse.example")
        XCTAssertEqual(configuration.resolvedAppStoreURL?.host, "apps.apple.com")
        XCTAssertEqual(configuration.resolvedPrivacyPolicyURL?.path, "/privacy")
        XCTAssertEqual(configuration.termsPolicy?.url.path, "/terms/v1")
        XCTAssertEqual(configuration.termsPolicy?.version, "2026-08-28")

        let unsafeConfiguration = try JSONDecoder().decode(PulseClientConfiguration.self, from: Data(#"""
        {
          "maintenance": true,
          "supportURL": "http://support.pulse.example",
          "privacyPolicyURL": "https://user:password@pulse.example/privacy",
          "termsURL": "http://pulse.example/terms",
          "termsVersion": "v1",
          "appStoreURL": "https://example.com/app/id123"
        }
        """#.utf8))
        XCTAssertNil(unsafeConfiguration.resolvedSupportURL)
        XCTAssertNil(unsafeConfiguration.resolvedPrivacyPolicyURL)
        XCTAssertNil(unsafeConfiguration.termsPolicy)
        XCTAssertNil(unsafeConfiguration.resolvedAppStoreURL)
    }

    func testCreateWorkPayloadCarriesTheExplicitRemixPreference() throws {
        let payload = CreateWorkPayload(
            title: "Private stargazer",
            instruction: "Make a quiet constellation garden",
            theme: "Night sky",
            tint: "violet",
            interaction: "constellation",
            creationMode: .original,
            parentWorkID: nil,
            allowRemix: false
        )

        let data = try JSONEncoder().encode(payload)
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(values["allowRemix"] as? Bool, false)
        XCTAssertNil(values["parentWorkId"])
        XCTAssertEqual(CreationPreferences.defaultAllowRemix, true)
    }

    @MainActor
    func testFeedCacheRestoresOnlyFreshPublicFeedWithoutViewerState() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "PulseFeedCacheTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FeedCacheStore(fileURL: url)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let work = InteractiveApp(
            title: "Cached constellation",
            creator: "maya",
            prompt: "Draw stars together",
            theme: "A safe offline preview",
            tint: "violet",
            likes: 9,
            comments: 2,
            remixes: 1,
            interaction: .constellation,
            isLiked: true
        )

        store.save(data: [work, work], nextCursor: "next-page", savedAt: now)
        let snapshot = try XCTUnwrap(store.load(now: now.addingTimeInterval(30)))
        XCTAssertEqual(snapshot.data.count, 1)
        XCTAssertFalse(snapshot.data[0].isLiked)
        XCTAssertEqual(snapshot.nextCursor, "next-page")

        let model = AppModel(feedCache: store)
        XCTAssertTrue(model.restoreCachedFeed(now: now.addingTimeInterval(30)))
        XCTAssertEqual(model.feed.map(\.id), [work.id])
        XCTAssertEqual(model.feedDataSource, .cached(savedAt: now))
        XCTAssertFalse(model.restoreCachedFeed(now: now.addingTimeInterval(FeedCacheStore.maximumAge + 1)))
    }

    func testFeedCacheDropsCursorWhenTheSnapshotIsTrimmed() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "PulseFeedCacheTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FeedCacheStore(fileURL: url)
        let works = (0...50).map { index in
            InteractiveApp(
                title: "Cached work \(index)",
                creator: "maya",
                prompt: "Cache pagination \(index)",
                theme: "A test",
                tint: "lime",
                likes: 0,
                comments: 0,
                remixes: 0,
                interaction: .garden
            )
        }

        store.save(data: works, nextCursor: "cursor-after-51")
        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.data.count, 50)
        XCTAssertNil(snapshot.nextCursor)
    }

    func testFeedCacheRejectsSnapshotFromAnotherAPIOriginAndClearsEmptyFeed() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "PulseFeedCacheTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let productionStore = FeedCacheStore(apiOrigin: try XCTUnwrap(URL(string: "https://api.pulse.example/v1")), fileURL: url)
        let stagingStore = FeedCacheStore(apiOrigin: try XCTUnwrap(URL(string: "https://api.staging.pulse.example/v1")), fileURL: url)
        let work = InteractiveApp(
            title: "Production work",
            creator: "maya",
            prompt: "Keep cache environments separate",
            theme: "A test",
            tint: "lime",
            likes: 0,
            comments: 0,
            remixes: 0,
            interaction: .garden
        )

        productionStore.save(data: [work], nextCursor: nil)
        XCTAssertNil(stagingStore.load())

        productionStore.save(data: [work], nextCursor: nil)
        productionStore.save(data: [], nextCursor: nil)
        XCTAssertNil(productionStore.load())
    }

    func testFeedCacheRejectsCorruptAndFutureSnapshots() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "PulseFeedCacheTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FeedCacheStore(fileURL: url)
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(store.load())

        let work = InteractiveApp(
            title: "Future cache",
            creator: "maya",
            prompt: "Test cache clock skew",
            theme: "A test",
            tint: "lime",
            likes: 0,
            comments: 0,
            remixes: 0,
            interaction: .garden
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.save(data: [work], nextCursor: nil, savedAt: now.addingTimeInterval(61))
        XCTAssertNil(store.load(now: now))
    }

    func testRemixDeepLinkAcceptsOnlyTheRegisteredPulseRoute() throws {
        let workID = try XCTUnwrap(UUID(uuidString: "59bcc7cc-7363-4413-8b79-b700667f2dde"))

        XCTAssertEqual(
            PulseDeepLink.parse(try XCTUnwrap(URL(string: "pulse://remix/59bcc7cc-7363-4413-8b79-b700667f2dde"))),
            .remix(workID)
        )
        XCTAssertNil(PulseDeepLink.parse(try XCTUnwrap(URL(string: "pulse://remix/not-a-work-id"))))
        XCTAssertNil(PulseDeepLink.parse(try XCTUnwrap(URL(string: "https://pulse.example/remix/59bcc7cc-7363-4413-8b79-b700667f2dde"))))
        XCTAssertNil(PulseDeepLink.parse(try XCTUnwrap(URL(string: "pulse://work/59bcc7cc-7363-4413-8b79-b700667f2dde"))))
        XCTAssertNil(PulseDeepLink.parse(try XCTUnwrap(URL(string: "pulse://remix/59bcc7cc-7363-4413-8b79-b700667f2dde/extra"))))
        XCTAssertEqual(
            PulseDeepLink.parse(try XCTUnwrap(URL(string: "pulse://report/aa12bc34de56ff78aa"))),
            .report(slug: "aa12bc34de56ff78aa")
        )
        XCTAssertNil(PulseDeepLink.parse(try XCTUnwrap(URL(string: "pulse://report/not-a-public-slug"))))
        XCTAssertNil(PulseDeepLink.parse(try XCTUnwrap(URL(string: "pulse://report/aa12bc34de56ff78aa/extra"))))
        XCTAssertEqual(
            PulseDeepLink.parse(
                try XCTUnwrap(URL(string: "https://play.pulse.test/remix/59bcc7cc-7363-4413-8b79-b700667f2dde?source=share")),
                universalLinkHost: "play.pulse.test"
            ),
            .remix(workID)
        )
        XCTAssertEqual(
            PulseDeepLink.parse(
                try XCTUnwrap(URL(string: "https://play.pulse.test/a/aa12bc34de56ff78aa?source=share")),
                universalLinkHost: "play.pulse.test"
            ),
            .publicWork(slug: "aa12bc34de56ff78aa")
        )
        XCTAssertNil(PulseDeepLink.parse(try XCTUnwrap(URL(string: "https://play.pulse.test/a/not-a-public-slug")), universalLinkHost: "play.pulse.test"))
        XCTAssertNil(PulseDeepLink.parse(try XCTUnwrap(URL(string: "https://attacker.pulse.test/remix/59bcc7cc-7363-4413-8b79-b700667f2dde")), universalLinkHost: "play.pulse.test"))
    }

    func testReleaseEndpointAndUniversalLinkConfigurationRejectsPlaceholdersAndLocalOrigins() throws {
        XCTAssertEqual(
            PulseEndpointConfiguration.approvedAPIBaseURL("https://api.pulse.test/v1", allowsLocalDevelopment: false)?.absoluteString,
            "https://api.pulse.test/v1"
        )
        XCTAssertNil(PulseEndpointConfiguration.approvedAPIBaseURL("http://localhost:8787/v1", allowsLocalDevelopment: false))
        XCTAssertEqual(
            PulseEndpointConfiguration.approvedAPIBaseURL("http://localhost:8787/v1", allowsLocalDevelopment: true)?.host,
            "localhost"
        )
        XCTAssertNil(PulseEndpointConfiguration.approvedAPIBaseURL("https://api.pulse.example/v1", allowsLocalDevelopment: false))
        XCTAssertNil(PulseEndpointConfiguration.approvedAPIBaseURL("https://api.pulse.test/v1?debug=true", allowsLocalDevelopment: false))
        XCTAssertNil(PulseEndpointConfiguration.approvedAPIBaseURL("https://api.pulse.test/api/v1", allowsLocalDevelopment: false))
        XCTAssertEqual(PulseEndpointConfiguration.approvedUniversalLinkHost("play.pulse.test"), "play.pulse.test")
        XCTAssertNil(PulseEndpointConfiguration.approvedUniversalLinkHost("configure-links.invalid"))
        XCTAssertNil(PulseEndpointConfiguration.approvedUniversalLinkHost("https://play.pulse.test"))
    }

    func testComposerDraftRoundTripsWithoutPrivateResourceBytes() throws {
        let parentID = try XCTUnwrap(UUID(uuidString: "59bcc7cc-7363-4413-8b79-b700667f2dde"))
        let assetID = try XCTUnwrap(UUID(uuidString: "30b86b66-7fd2-4cdc-9dc2-0733f4e64c25"))
        let workID = try XCTUnwrap(UUID(uuidString: "8c92f064-fc35-4c91-a83e-f40e52ed89d3"))
        let generationID = try XCTUnwrap(UUID(uuidString: "3327fcbc-d936-4279-a5ed-e6083d52a540"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let draft = ComposerDraft(
            ownerID: "user-123",
            parentWorkID: parentID,
            instruction: "Turn it into a calmer constellation",
            assetIDs: [assetID],
            workID: workID,
            generationID: generationID,
            workIdempotencyKey: "work-key",
            generationIdempotencyKey: "generation-key",
            createdAt: date,
            updatedAt: date
        )

        let encoded = try JSONEncoder().encode(draft)
        let restored = try JSONDecoder().decode(ComposerDraft.self, from: encoded)

        XCTAssertEqual(restored, draft)
        XCTAssertEqual(restored.storageAccount, "user-123:59bcc7cc-7363-4413-8b79-b700667f2dde")
        XCTAssertNotEqual(
            ComposerDraft.storageAccount(ownerID: "other-user", parentWorkID: parentID),
            restored.storageAccount
        )
        XCTAssertFalse(String(data: encoded, encoding: .utf8)?.contains("objectKey") == true)
    }

    func testPendingAssetSafetyRetryPersistsOnlyScopedRecoveryMetadata() throws {
        let parentID = try XCTUnwrap(UUID(uuidString: "59bcc7cc-7363-4413-8b79-b700667f2dde"))
        let assetID = try XCTUnwrap(UUID(uuidString: "30b86b66-7fd2-4cdc-9dc2-0733f4e64c25"))
        let retry = PendingAssetSafetyRetry(
            assetID: assetID,
            fileName: "private-sound.wav",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoded = try JSONEncoder().encode(retry)
        XCTAssertEqual(try JSONDecoder().decode(PendingAssetSafetyRetry.self, from: encoded), retry)
        XCTAssertEqual(
            PendingAssetSafetyRetryStore.storageAccount(ownerID: "user-123", parentWorkID: parentID),
            "user-123:59bcc7cc-7363-4413-8b79-b700667f2dde"
        )
        XCTAssertNotEqual(
            PendingAssetSafetyRetryStore.storageAccount(ownerID: "other-user", parentWorkID: parentID),
            PendingAssetSafetyRetryStore.storageAccount(ownerID: "user-123", parentWorkID: parentID)
        )
        let serialized = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(serialized.contains("objectKey"))
        XCTAssertFalse(serialized.contains("uploadGrant"))
        XCTAssertFalse(serialized.contains("privateBytes"))
    }

    func testBackgroundAssetRecoveryRecordNeverSerializesGrantOrPrivateBytes() throws {
        let parentID = try XCTUnwrap(UUID(uuidString: "59bcc7cc-7363-4413-8b79-b700667f2dde"))
        let assetID = try XCTUnwrap(UUID(uuidString: "30b86b66-7fd2-4cdc-9dc2-0733f4e64c25"))
        let record = BackgroundAssetUploadRecord(
            assetID: assetID,
            context: AssetUploadRecoveryContext(ownerID: "user-123", parentWorkID: parentID),
            fileName: "private-sound.wav",
            mediaType: "audio/wav",
            localFileName: "opaque-protected-file.material",
            taskIdentifier: 42,
            state: .uploading,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoded = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(BackgroundAssetUploadRecord.self, from: encoded), record)
        let serialized = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(serialized.contains("uploadGrant"))
        XCTAssertFalse(serialized.contains("signedURL"))
        XCTAssertFalse(serialized.contains("headers"))
        XCTAssertFalse(serialized.contains("objectKey"))
        XCTAssertFalse(serialized.contains("accessToken"))
        XCTAssertFalse(serialized.contains("privateBytes"))
    }

    func testCommentMapsWorkID() throws {
        let data = Data(#"""
        {
          "id":"8c92f064-fc35-4c91-a83e-f40e52ed89d3",
          "workId":"59bcc7cc-7363-4413-8b79-b700667f2dde",
          "author":"you",
          "score":5,
          "body":"Alive and responsive",
          "status":"hidden",
          "createdAt":"2026-08-20T08:09:07Z"
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let comment = try decoder.decode(AppComment.self, from: data)

        XCTAssertEqual(comment.workID.uuidString.lowercased(), "59bcc7cc-7363-4413-8b79-b700667f2dde")
        XCTAssertTrue(comment.isHiddenFromOthers)
    }

    func testCommentPagePreservesTheStablePaginationCursor() throws {
        let data = Data(#"""
        {
          "data":[
            {
              "id":"8c92f064-fc35-4c91-a83e-f40e52ed89d3",
              "workId":"59bcc7cc-7363-4413-8b79-b700667f2dde",
              "author":"you",
              "score":5,
              "body":"First page comment",
              "status":"visible",
              "createdAt":"2026-08-20T08:09:07Z"
            }
          ],
          "nextCursor":"8c92f064-fc35-4c91-a83e-f40e52ed89d3"
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let page = try decoder.decode(CommentPage.self, from: data)

        XCTAssertEqual(page.data.count, 1)
        XCTAssertEqual(page.nextCursor, page.data.first?.id.uuidString.lowercased())
    }

    func testPendingCommentIntentKeepsTheExactDraftUntilAuthenticationFinishes() {
        let workID = UUID(uuidString: "59bcc7cc-7363-4413-8b79-b700667f2dde")!
        let intent = PendingCommentIntent(
            workID: workID,
            body: "A thoughtful note",
            score: 4,
            idempotencyKey: "comment-draft-key"
        )

        XCTAssertEqual(intent.workID, workID)
        XCTAssertEqual(intent.body, "A thoughtful note")
        XCTAssertEqual(intent.score, 4)
        XCTAssertEqual(intent.idempotencyKey, "comment-draft-key")
        XCTAssertEqual(intent.returnDestination, .comments)
    }

    func testPendingCreationIntentKeepsOnlyThePromptAndOriginalOrRemixContext() {
        let parentWorkID = UUID(uuidString: "59bcc7cc-7363-4413-8b79-b700667f2dde")!
        let original = PendingCreationIntent(parentWorkID: nil, instruction: "Build a small touch garden")
        let remix = PendingCreationIntent(parentWorkID: parentWorkID, instruction: "Make the colors warmer")

        XCTAssertNil(original.parentWorkID)
        XCTAssertEqual(original.instruction, "Build a small touch garden")
        XCTAssertEqual(original.returnDestination, .create)
        XCTAssertEqual(remix.parentWorkID, parentWorkID)
        XCTAssertEqual(remix.instruction, "Make the colors warmer")
        XCTAssertEqual(remix.returnDestination, .create)
    }

    func testPendingReportIntentKeepsTheCurrentTargetAndDraftForExplicitPostLoginReview() {
        let intent = PendingReportIntent(
            targetType: "work",
            targetID: "59bcc7cc-7363-4413-8b79-b700667f2dde",
            targetTitle: "A work title",
            reason: "Unsafe interactive behavior",
            details: "The start button opens an unexpected external page."
        )

        XCTAssertEqual(intent.targetType, "work")
        XCTAssertEqual(intent.targetID, "59bcc7cc-7363-4413-8b79-b700667f2dde")
        XCTAssertEqual(intent.targetTitle, "A work title")
        XCTAssertEqual(intent.reason, "Unsafe interactive behavior")
        XCTAssertEqual(intent.details, "The start button opens an unexpected external page.")
        XCTAssertEqual(intent.returnDestination, .report)
    }

    func testAccountDeletionConfirmsTheSameReceiptAfterItsDeleteResponseIsLost() async throws {
        AccountDeletionRecoveryURLProtocol.reset()
        defer { AccountDeletionRecoveryURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountDeletionRecoveryURLProtocol.self]
        let client = PulseAPIClient(
            baseURL: try XCTUnwrap(URL(string: "https://api.pulse.test/v1")),
            urlSession: URLSession(configuration: configuration)
        )
        let idempotencyKey = "8d7b4939-86cb-4c6c-bd56-bf4a575b5462"

        try await client.deleteAccount(
            confirmation: "DELETE pulse.creator",
            authorization: AppleDeletionAuthorization(identityToken: "fresh-token", nonce: "fresh-nonce", authorizationCode: "fresh-code"),
            idempotencyKey: idempotencyKey
        )

        let requests = AccountDeletionRecoveryURLProtocol.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["DELETE", "GET"])
        XCTAssertEqual(requests.map(\.url?.path), ["/v1/me", "/v1/account-deletion-status"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Idempotency-Key") }, [idempotencyKey, idempotencyKey])
    }

    @MainActor
    func testFeedRefreshReplacesOnlyAfterSuccessAndRetainsCurrentFeedAfterFailure() async throws {
        FeedRefreshURLProtocol.reset()
        defer { FeedRefreshURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedRefreshURLProtocol.self]
        let client = PulseAPIClient(
            baseURL: try XCTUnwrap(URL(string: "https://api.pulse.test/v1")),
            urlSession: URLSession(configuration: configuration)
        )
        let model = AppModel(api: client)
        let existing = makeFeedRefreshWork(title: "Existing feed item")
        let refreshed = makeFeedRefreshWork(title: "Fresh feed item")
        model.feed = [existing]
        model.feedDataSource = .live

        try FeedRefreshURLProtocol.configure(statusCode: 503, works: [])
        await model.refreshFeed()

        XCTAssertEqual(model.feed, [existing])
        XCTAssertEqual(model.feedError, "Couldn’t refresh the latest works. Your current Feed is still available.")
        XCTAssertFalse(model.isLoadingFeed)
        XCTAssertFalse(model.isRefreshingFeed)

        try FeedRefreshURLProtocol.configure(statusCode: 200, works: [refreshed])
        await model.refreshFeed()

        XCTAssertEqual(model.feed, [refreshed])
        XCTAssertNil(model.feedError)
        XCTAssertEqual(model.feedDataSource, .live)
        let requests = FeedRefreshURLProtocol.capturedRequests()
        XCTAssertEqual(requests.map(\.url?.path), ["/v1/feed", "/v1/feed"])
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Pulse-Client-Platform"), "ios")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Pulse-Client-Version"), PulseAppVersion.current.marketingVersion)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Pulse-Client-Build"), String(PulseAppVersion.current.buildNumber))
        }
    }

    @MainActor
    func testOfflineReadOnlyFeedNeverIssuesPullToRefreshRequest() async throws {
        FeedRefreshURLProtocol.reset()
        defer { FeedRefreshURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedRefreshURLProtocol.self]
        let client = PulseAPIClient(
            baseURL: try XCTUnwrap(URL(string: "https://api.pulse.test/v1")),
            urlSession: URLSession(configuration: configuration)
        )
        let model = AppModel(api: client)
        let cached = makeFeedRefreshWork(title: "Saved feed item")
        model.feed = [cached]
        model.feedDataSource = .cached(savedAt: .now)
        model.isOfflineReadOnly = true

        await model.refreshFeed()

        XCTAssertEqual(model.feed, [cached])
        XCTAssertTrue(FeedRefreshURLProtocol.capturedRequests().isEmpty)
    }
}

private func makeFeedRefreshWork(title: String) -> InteractiveApp {
    InteractiveApp(
        title: title,
        creator: "pulse",
        prompt: "A safe Feed refresh fixture",
        theme: "quiet orbit",
        tint: "lime",
        likes: 0,
        comments: 0,
        remixes: 0,
        interaction: .garden,
        contentReviewStatus: .approved,
        ageRating: .fourPlus
    )
}

private struct FeedRefreshPage: Encodable {
    let data: [InteractiveApp]
    let nextCursor: String?
}

private final class FeedRefreshURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var responseStatusCode = 200
    nonisolated(unsafe) private static var responseBody = Data(#"{"data":[],"nextCursor":null}"#.utf8)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.pulse.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let statusCode = Self.responseStatusCode
        let body = Self.responseBody
        Self.lock.unlock()

        guard let client, let url = request.url, request.httpMethod == "GET", url.path == "/v1/feed" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func configure(statusCode: Int, works: [InteractiveApp]) throws {
        let body = try JSONEncoder().encode(FeedRefreshPage(data: works, nextCursor: nil))
        configureRaw(statusCode: statusCode, body: body)
    }

    static func configureRaw(statusCode: Int, body: Data) {
        lock.lock()
        responseStatusCode = statusCode
        responseBody = body
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        requests = []
        responseStatusCode = 200
        responseBody = Data(#"{"data":[],"nextCursor":null}"#.utf8)
        lock.unlock()
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class GenerationCapabilitiesURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) static var responseBody = Data(#"{"mode":"live","modelBacked":true}"#.utf8)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.pulse.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.paths.append(request.url?.path ?? "")
        let body = Self.responseBody
        Self.lock.unlock()
        guard let client, let url = request.url, url.path == "/v1/generation-capabilities" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        paths = []
        responseBody = Data(#"{"mode":"live","modelBacked":true}"#.utf8)
        lock.unlock()
    }

    static func capturedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

private actor PreviewLoadCounter {
    private(set) var count = 0

    func load(_ data: Data) async -> Data? {
        count += 1
        try? await Task.sleep(for: .milliseconds(20))
        return data
    }
}

private final class AccountDeletionRecoveryURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.pulse.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        Self.lock.unlock()

        guard let client, let url = request.url else { return }
        if request.httpMethod == "DELETE" && url.path == "/v1/me" {
            client.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        if request.httpMethod == "GET" && url.path == "/v1/account-deletion-status" {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data(#"{"deleted":true}"#.utf8))
            client.urlProtocolDidFinishLoading(self)
            return
        }
        client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        requests = []
        lock.unlock()
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}
