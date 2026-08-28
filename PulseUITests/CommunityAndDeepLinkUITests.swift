import Foundation
import XCTest

@MainActor
final class CommunityAndDeepLinkUITests: XCTestCase {
    private let isolatedAPIBaseURL = "http://127.0.0.1:18787/v1"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCommentAndReportFlowsUseTheSeededWork() throws {
        let app = XCUIApplication()
        configureIsolatedAPI(for: app)
        app.launch()

        let comments = app.buttons["Comments"].firstMatch
        XCTAssertTrue(comments.waitForExistence(timeout: 12), "Seeded Feed did not expose the comments action")
        comments.tap()

        let comment = "UI regression comment"
        let input = app.textFields["community.comment.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 8), "Comment composer did not open")
        input.tap()
        input.typeText(comment)
        let submit = app.buttons["community.comment.submit"]
        XCTAssertTrue(submit.isEnabled, "Comment submission stayed disabled after input")
        submit.tap()
        XCTAssertTrue(app.staticTexts[comment].waitForExistence(timeout: 8), "Posted comment did not appear in the thread")

        app.buttons["Done"].tap()
        let safetyMenu = app.buttons["feed.work-safety"].firstMatch
        XCTAssertTrue(safetyMenu.waitForExistence(timeout: 5), "Feed safety menu did not appear")
        safetyMenu.tap()
        let report = app.buttons["Report this work"]
        XCTAssertTrue(report.waitForExistence(timeout: 5), "Work report action did not appear")
        report.tap()

        XCTAssertTrue(app.navigationBars["Report content"].waitForExistence(timeout: 5), "Report form did not open")
        app.swipeUp()
        let reportSubmit = app.buttons["Submit report"].firstMatch
        XCTAssertTrue(reportSubmit.waitForExistence(timeout: 5), "Report form did not expose its submit action")
        reportSubmit.tap()
        XCTAssertTrue(app.staticTexts["Report received"].waitForExistence(timeout: 8), "Report confirmation did not appear")

        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "community-comment-and-report"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testHiddenCommentExplainsItsStatusOnlyToTheAuthor() async throws {
        let workID = try await seededWorkID()
        let hiddenComment = "Comment hidden for UI regression"
        try await seedHiddenComment(workID: workID, body: hiddenComment)

        let app = XCUIApplication()
        configureIsolatedAPI(for: app)
        app.launch()

        let comments = app.buttons["Comments"].firstMatch
        XCTAssertTrue(comments.waitForExistence(timeout: 12), "Seeded Feed did not expose the comments action")
        comments.tap()

        XCTAssertTrue(app.staticTexts[hiddenComment].waitForExistence(timeout: 8), "A hidden comment owned by the active user did not remain available as a status record")
        XCTAssertTrue(app.descendants(matching: .any)["community.comment.hidden-status"].waitForExistence(timeout: 5), "Hidden comment did not explain that it was removed from the public conversation")
        XCTAssertTrue(app.buttons["Review Community guidelines"].waitForExistence(timeout: 5), "Hidden comment did not provide a direct Community guidelines entry")
    }

    func testCommentPaginationLoadsTheNextServerPageWithoutReplacingTheDiscussion() async throws {
        let workID = try await seededWorkID()
        let oldestComment = "Pagination comment 01"
        try await seedVisibleComments(workID: workID, count: 31)

        let app = XCUIApplication()
        configureIsolatedAPI(for: app)
        app.launch()

        let comments = app.buttons["Comments"].firstMatch
        XCTAssertTrue(comments.waitForExistence(timeout: 12), "Seeded Feed did not expose the comments action")
        comments.tap()

        let loadMore = app.buttons["community.comments.load-more"]
        XCTAssertTrue(loadMore.waitForExistence(timeout: 8), "A next cursor did not expose Load more comments")
        for _ in 0..<6 where !loadMore.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(loadMore.isHittable, "Load more comments could not be reached in the discussion")
        XCTAssertFalse(app.staticTexts[oldestComment].exists, "The next page was rendered before the user requested it")

        loadMore.tap()
        XCTAssertTrue(app.staticTexts[oldestComment].waitForExistence(timeout: 8), "The older server page did not append after Load more comments")
    }

    func testPulseRemixDeepLinkRestoresTheRemixComposer() async throws {
        let workID = try await seededWorkID()
        let app = XCUIApplication()
        configureIsolatedAPI(for: app)
        app.launchEnvironment["PULSE_UI_TEST_DEEP_LINK"] = "pulse://remix/\(workID)"
        app.launch()

        XCTAssertTrue(app.staticTexts["REMIX OF"].waitForExistence(timeout: 12), "Remix deep link did not open the confirmed Remix composer")
        XCTAssertTrue(app.textViews["creation.prompt"].waitForExistence(timeout: 5), "Remix composer did not retain an editable instruction field")
        XCTAssertTrue(app.buttons["creation.generate"].waitForExistence(timeout: 5), "Remix composer did not expose the generation action")
    }

    func testInvalidRemixDeepLinkShowsARecoverableUnavailablePage() throws {
        let app = XCUIApplication()
        configureIsolatedAPI(for: app)
        app.launchEnvironment["PULSE_UI_TEST_DEEP_LINK"] = "pulse://remix/00000000-0000-4000-8000-000000000000"
        app.launch()

        XCTAssertTrue(app.staticTexts["This work is no longer available"].waitForExistence(timeout: 12), "An invalid shared-work link did not show the global unavailable page")
        XCTAssertTrue(app.buttons["Try again"].exists, "Unavailable page did not retain a recovery action")
        XCTAssertTrue(app.buttons["Back to Home"].exists, "Unavailable page did not offer a safe Home route")

        app.buttons["Back to Home"].tap()
        XCTAssertTrue(app.buttons["Comments"].firstMatch.waitForExistence(timeout: 5), "Returning from an unavailable link did not restore the Home Feed")
    }

    func testPublicReportDeepLinkRevalidatesTheWorkBeforeOpeningTheReportForm() async throws {
        let slug = try await seededPublicWorkSlug()
        let app = XCUIApplication()
        configureIsolatedAPI(for: app)
        app.launchEnvironment["PULSE_UI_TEST_DEEP_LINK"] = "pulse://report/\(slug)"
        app.launch()

        XCTAssertTrue(app.navigationBars["Report content"].waitForExistence(timeout: 12), "A public report link did not open the report form after revalidating its work")
        XCTAssertTrue(app.staticTexts["Reporting"].exists, "The report form did not expose its reporting context")
    }

    func testArtifactNetworkFailureKeepsABrowsableStaticPreviewAndRetry() throws {
        let app = XCUIApplication()
        configureIsolatedAPI(for: app)
        app.launchEnvironment["PULSE_UI_TEST_ARTIFACT_FAILURE"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Interactive version needs a connection"].waitForExistence(timeout: 12), "A failed Artifact request did not explain that the interactive version needs a connection")
        XCTAssertTrue(app.staticTexts["Reconnect to load the interactive version."].exists, "Artifact failure exposed no actionable recovery copy")
        XCTAssertTrue(app.buttons["Try again"].exists, "Artifact failure did not retain a retry action")
        let comments = app.buttons["Comments"].firstMatch
        XCTAssertTrue(comments.exists, "Artifact failure prevented the viewer from continuing to browse the work")
        comments.tap()
        XCTAssertTrue(app.textFields["community.comment.input"].waitForExistence(timeout: 5), "Artifact failure blocked a still-available browsing action")
    }

    func testWorkSafetyMenuLinksToCommunityGuidelines() throws {
        let app = XCUIApplication()
        configureIsolatedAPI(for: app)
        app.launch()

        let safetyMenu = app.buttons["feed.work-safety"].firstMatch
        XCTAssertTrue(safetyMenu.waitForExistence(timeout: 12), "Feed safety menu did not appear")
        safetyMenu.tap()
        let guidelines = app.buttons["Community guidelines"]
        XCTAssertTrue(guidelines.waitForExistence(timeout: 5), "Safety menu did not include community guidelines")
        guidelines.tap()

        XCTAssertTrue(app.navigationBars["Community guidelines"].waitForExistence(timeout: 5), "Community guidelines did not open from the safety menu")
        XCTAssertTrue(app.staticTexts["Keep Pulse safe"].waitForExistence(timeout: 5), "Community guideline content did not load")
        let support = app.buttons["community-guidelines.contact-support"]
        XCTAssertTrue(support.waitForExistence(timeout: 5), "Community guidelines did not expose the configured support contact")
        XCTAssertTrue(support.isHittable, "Community guidelines did not expose the configured support contact")
    }

    func testTabSwitchPreservesProfileStackAndReselectReturnsToItsRoot() throws {
        let app = XCUIApplication()
        configureIsolatedAPI(for: app)
        app.launch()

        let profileTab = app.buttons["app.tab.profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 12), "Profile tab did not appear")
        profileTab.tap()

        let settings = app.buttons["Profile and safety settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "Profile settings entry did not appear")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Profile settings did not open")
        XCTAssertTrue(app.switches["settings.creation.allow-remix"].waitForExistence(timeout: 5), "Settings did not expose the Remix default for future works")
        let version = app.descendants(matching: .any)["settings.app-version"]
        for _ in 0..<4 where !version.exists {
            app.swipeUp()
        }
        XCTAssertTrue(version.waitForExistence(timeout: 5), "Settings did not expose the installed app version and build")
        XCTAssertTrue(version.label.hasPrefix("Pulse Version "), "Settings app version did not include both the product and version label")
        XCTAssertTrue(version.label.contains("("), "Settings app version did not include the build number")

        app.buttons["app.tab.home"].tap()
        XCTAssertTrue(app.buttons["Comments"].firstMatch.waitForExistence(timeout: 5), "Home tab did not reopen")

        profileTab.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Profile navigation stack was discarded after switching tabs")

        profileTab.tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5), "Reselecting Profile did not return to its root")
        XCTAssertFalse(app.navigationBars["Settings"].exists, "Settings remained visible after reselecting Profile")
    }

    func testProfileShowsOnlyTheReporterSafeReviewStatus() async throws {
        let workID = try await seededWorkID()
        try await seedReporterStatus(workID: workID)

        let app = XCUIApplication()
        configureIsolatedAPI(for: app)
        app.launch()

        let profileTab = app.buttons["app.tab.profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 12), "Profile tab did not appear")
        profileTab.tap()
        let settings = app.buttons["Profile and safety settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "Profile settings entry did not appear")
        settings.tap()

        let reports = app.buttons["Your reports"]
        for _ in 0..<4 where !reports.exists || !reports.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(reports.isHittable, "Settings did not expose the reporter history entry")
        reports.tap()

        XCTAssertTrue(app.navigationBars["Your reports"].waitForExistence(timeout: 8), "Reporter history did not open")
        XCTAssertTrue(app.staticTexts["Under review"].waitForExistence(timeout: 8), "Reporter history did not show the safe investigating state")
        XCTAssertTrue(app.staticTexts["Pulse is reviewing this report."].exists, "Reporter history did not explain the safe status")
        XCTAssertFalse(app.staticTexts["Internal fixture-only moderator note."].exists, "Reporter history leaked an internal moderator note")
        XCTAssertFalse(app.staticTexts["local-operator"].exists, "Reporter history leaked the moderator identity")

        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "profile-safe-report-history"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testProfileShowsTheCreatorOnlyVersionTimeline() async throws {
        let workTitle = "Version timeline fixture"
        try await createOwnedVersionFixture(title: workTitle)

        let app = XCUIApplication()
        configureIsolatedAPI(for: app)
        app.launch()

        let profileTab = app.buttons["app.tab.profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 12), "Profile tab did not appear")
        profileTab.tap()

        let versions = app.buttons["View versions for \(workTitle)"]
        XCTAssertTrue(versions.waitForExistence(timeout: 8), "Profile did not expose the owned work's version history")
        versions.tap()

        XCTAssertTrue(app.navigationBars["Versions"].waitForExistence(timeout: 8), "Version history did not open")
        let firstCandidate = app.descendants(matching: .any)["profile.work-version.1"]
        XCTAssertTrue(firstCandidate.waitForExistence(timeout: 5), "The immutable first candidate was not listed")
        XCTAssertTrue(firstCandidate.isHittable, "The first candidate was hidden below the initial version sheet viewport")
        XCTAssertTrue(firstCandidate.label.contains("Version 1"), "The candidate's version number was not available to VoiceOver")
        XCTAssertTrue(firstCandidate.label.contains("current"), "The active candidate was not marked current")
        XCTAssertTrue(firstCandidate.label.contains("Ready"), "The safe lifecycle summary was not shown")
        XCTAssertTrue(app.staticTexts["Candidate history"].exists, "The version list did not identify its purpose")

        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "profile-version-timeline"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testProfilePreviewsOnlyTheAuthorsReadyHistoricalCandidate() async throws {
        let workTitle = "Historical preview fixture"
        try await createOwnedHistoricalVersionFixture(title: workTitle)

        let app = XCUIApplication()
        configureIsolatedAPI(for: app)
        app.launch()

        let profileTab = app.buttons["app.tab.profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 12), "Profile tab did not appear")
        profileTab.tap()

        let versions = app.buttons["View versions for \(workTitle)"]
        XCTAssertTrue(versions.waitForExistence(timeout: 8), "Profile did not expose the historical fixture's versions")
        versions.tap()
        XCTAssertTrue(app.navigationBars["Versions"].waitForExistence(timeout: 8), "Version history did not open")

        let historicalPreview = app.buttons["profile.work-version.preview.1"]
        XCTAssertTrue(historicalPreview.waitForExistence(timeout: 5), "Ready historical candidate did not expose a private preview")
        for _ in 0..<3 where !historicalPreview.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(historicalPreview.isHittable, "Historical preview action could not be reached")
        historicalPreview.tap()

        XCTAssertTrue(app.navigationBars["Candidate preview"].waitForExistence(timeout: 8), "Private candidate preview did not open")
        XCTAssertTrue(app.staticTexts["Private historical candidate · Version 1"].exists, "Preview did not identify the candidate as private and historical")
        XCTAssertTrue(app.descendants(matching: .any)["profile.work-version.preview-player"].waitForExistence(timeout: 5), "Private candidate preview did not use the constrained artifact player")
        XCTAssertFalse(app.buttons["Publish"].exists, "Historical preview must not offer a publication bypass")
        XCTAssertFalse(app.buttons["Make current"].exists, "Historical preview must not offer a current-version switch")

        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "profile-private-historical-candidate-preview"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testProfileFiltersCreatorLifecycleAndKeepsRevocationsDistinct() async throws {
        let workTitle = "Revoked link lifecycle fixture"
        let workID = try await createOwnedRevokedWorkFixture(title: workTitle)

        let app = XCUIApplication()
        configureIsolatedAPI(for: app)
        app.launch()

        let profileTab = app.buttons["app.tab.profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 12), "Profile tab did not appear")
        profileTab.tap()

        let draftsFilter = app.buttons["profile.work-filter.drafts"]
        XCTAssertTrue(draftsFilter.waitForExistence(timeout: 8), "Profile did not expose a draft filter")
        draftsFilter.tap()
        XCTAssertTrue(app.staticTexts["No drafts"].waitForExistence(timeout: 5), "A revoked work was incorrectly presented as an ordinary draft")

        let revokedFilter = app.buttons["profile.work-filter.revoked"]
        XCTAssertTrue(revokedFilter.waitForExistence(timeout: 8), "Profile did not expose a revoked-link filter")
        revokedFilter.tap()
        XCTAssertEqual(revokedFilter.value as? String, "Selected", "The revoked-link filter did not announce its selected state")
        XCTAssertTrue(app.staticTexts[workTitle].waitForExistence(timeout: 5), "A creator-revoked work was missing from the revoked filter")
        XCTAssertGreaterThanOrEqual(revokedFilter.frame.minX, app.frame.minX, "The selected revoked filter was clipped on the leading edge")
        XCTAssertLessThanOrEqual(revokedFilter.frame.maxX, app.frame.maxX, "The selected revoked filter was clipped on the trailing edge")
        let revocationNotice = app.buttons["profile.work-details.\(workID)"]
        for _ in 0..<5 where !revocationNotice.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(revocationNotice.isHittable, "The revoked work did not explain why its public link is unavailable")
        XCTAssertTrue(revocationNotice.label.contains("Public link revoked"), "The lifecycle state was not available to VoiceOver")

        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "profile-lifecycle-filters"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testProfileWorkDetailsShowsTheCurrentAuthorPreviewAndReviewAction() async throws {
        let workTitle = "Author detail preview fixture"
        let workID = try await createOwnedVersionFixture(title: workTitle)

        let app = XCUIApplication()
        configureIsolatedAPI(for: app)
        app.launch()

        let profileTab = app.buttons["app.tab.profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 12), "Profile tab did not appear")
        profileTab.tap()

        let details = app.buttons["profile.work-details.\(workID)"]
        XCTAssertTrue(details.waitForExistence(timeout: 8), "Profile did not make the owned work details reachable")
        XCTAssertTrue(details.label.contains("Updated"), "Profile did not expose the work's freshness to VoiceOver")
        XCTAssertTrue(details.label.contains("Version 1"), "Profile did not expose the current candidate version to VoiceOver")
        details.tap()

        XCTAssertTrue(app.navigationBars["Work details"].waitForExistence(timeout: 8), "Work details did not open")
        XCTAssertTrue(app.descendants(matching: .any)["profile.work-detail.preview"].waitForExistence(timeout: 5), "Work details did not retain the current author preview")
        XCTAssertTrue(app.descendants(matching: .any)["profile.work-detail.lifecycle"].label.contains("Private draft"), "Work details did not state that the candidate remains private")
        XCTAssertTrue(app.staticTexts["Current candidate · Version 1"].exists, "Work details did not name its current immutable candidate")
        XCTAssertTrue(app.staticTexts["Original work"].exists, "Work details did not retain the work's origin")
        XCTAssertTrue(app.buttons["Continue review"].exists, "A ready private candidate did not provide the review continuation")
        XCTAssertTrue(app.buttons["Version history"].exists, "Work details did not retain the immutable history entry")

        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "profile-work-details"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testProfileWorkDetailsSharesOnlyTheCurrentLiveVersion() async throws {
        let workTitle = "Live share fixture"
        let workID = try await createOwnedPublishedWorkFixture(title: workTitle)

        let app = XCUIApplication()
        configureIsolatedAPI(for: app)
        app.launch()

        let profileTab = app.buttons["app.tab.profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 12), "Profile tab did not appear")
        profileTab.tap()

        let details = app.buttons["profile.work-details.\(workID)"]
        XCTAssertTrue(details.waitForExistence(timeout: 8), "Published fixture did not appear in Profile")
        details.tap()
        XCTAssertTrue(app.navigationBars["Work details"].waitForExistence(timeout: 8), "Published work details did not open")
        XCTAssertTrue(app.staticTexts["Public version · Version 1"].waitForExistence(timeout: 5), "Details did not identify the current public version")

        let remixPermission = app.switches["profile.work-detail.allow-remix"]
        for _ in 0..<3 where !remixPermission.exists || !remixPermission.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(remixPermission.isHittable, "Published work details did not expose a usable creator Remix permission")
        XCTAssertEqual(remixPermission.value as? String, "1", "Published fixture did not start with Remix enabled")
        remixPermission.tap()
        let remixDisabled = NSPredicate(format: "value == %@", "0")
        let remixPermissionUpdated = expectation(for: remixDisabled, evaluatedWith: remixPermission, handler: nil)
        await fulfillment(of: [remixPermissionUpdated], timeout: 8)

        remixPermission.tap()
        let remixEnabled = NSPredicate(format: "value == %@", "1")
        let remixPermissionRestored = expectation(for: remixEnabled, evaluatedWith: remixPermission, handler: nil)
        await fulfillment(of: [remixPermissionRestored], timeout: 8)

        let share = app.buttons["profile.work-detail.share"]
        for _ in 0..<3 where !share.exists || !share.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(share.isHittable, "Published work details did not expose the direct public-link share action")
        let revoke = app.buttons["profile.work-detail.revoke-link"]
        XCTAssertTrue(revoke.exists, "Published work details did not expose the confirmation-based public-link revocation action")
        share.tap()

        XCTAssertTrue(app.navigationBars["Share"].waitForExistence(timeout: 8), "Public-link sharing sheet did not open")
        XCTAssertTrue(app.staticTexts["PUBLIC LINK"].exists, "Share sheet did not confirm a public URL")
        XCTAssertTrue(app.buttons["Share public link"].exists, "Share sheet did not preserve the system share action")
        XCTAssertFalse(app.staticTexts["Public link unavailable"].exists, "Current live version was incorrectly treated as private")

        app.navigationBars["Share"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Work details"].waitForExistence(timeout: 5), "Closing Share did not return to the published work details")
        XCTAssertTrue(revoke.waitForExistence(timeout: 5), "The confirmation-based revocation action disappeared after sharing")
        revoke.tap()

        let revokeAlert = app.alerts["Revoke public link?"]
        XCTAssertTrue(revokeAlert.waitForExistence(timeout: 5), "Revocation from work details did not require confirmation")
        let impactExplanation = revokeAlert.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "will stop working immediately")
        ).firstMatch
        XCTAssertTrue(impactExplanation.exists, "Revocation confirmation did not explain the link impact")
        XCTAssertTrue(impactExplanation.label.contains("private draft"), "Revocation confirmation did not explain that the private draft remains available")
        revokeAlert.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5), "Cancelling revocation did not return to Profile safely")

        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "profile-current-live-version-share"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testProfileRemixOpensOnlyTheServerConfirmedOriginalWork() async throws {
        let workTitle = "Original navigation Remix fixture"
        let remixID = try await createOwnedRemixFixture(title: workTitle)

        let app = XCUIApplication()
        configureIsolatedAPI(for: app)
        app.launch()

        let profileTab = app.buttons["app.tab.profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 12), "Profile tab did not appear")
        profileTab.tap()

        let details = app.buttons["profile.work-details.\(remixID)"]
        XCTAssertTrue(details.waitForExistence(timeout: 8), "Profile did not expose the Remix fixture")
        details.tap()
        let origin = app.descendants(matching: .any)["profile.work-detail.origin"]
        XCTAssertTrue(origin.waitForExistence(timeout: 5), "The Remix origin summary was not shown")
        XCTAssertTrue(origin.label.contains("Remix of @"), "The Remix origin summary did not preserve its public attribution")

        let showLineage = app.buttons["profile.work-detail.show-lineage"]
        XCTAssertTrue(showLineage.waitForExistence(timeout: 5), "A Remix did not offer an on-demand lineage")
        showLineage.tap()
        XCTAssertTrue(app.staticTexts["From the original to this Remix"].waitForExistence(timeout: 8), "The complete public Remix lineage did not load")

        let openOriginal = app.buttons["profile.work-detail.open-original"]
        XCTAssertTrue(openOriginal.waitForExistence(timeout: 5), "A Remix did not offer an original-work entry")
        openOriginal.tap()

        XCTAssertTrue(app.buttons["Close shared work"].waitForExistence(timeout: 8), "The original work did not open in the existing safe player")
        XCTAssertFalse(app.descendants(matching: .any)["profile.work-detail.original-unavailable"].exists, "A confirmed original was incorrectly shown as unavailable")
    }

    private func configureIsolatedAPI(for app: XCUIApplication) {
        app.launchEnvironment["PULSE_API_BASE_URL"] = isolatedAPIBaseURL
    }

    private func seededWorkID() async throws -> String {
        let url = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/feed?limit=1"))
        let (data, response) = try await URLSession.shared.data(from: url)
        let statusCode = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
        XCTAssertEqual(statusCode, 200, "The isolated API did not return its seeded Feed")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try XCTUnwrap(json["data"] as? [[String: Any]])
        let first = try XCTUnwrap(items.first)
        return try XCTUnwrap(first["id"] as? String)
    }

    private func seededPublicWorkSlug() async throws -> String {
        let url = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/feed?limit=1"))
        let (data, response) = try await URLSession.shared.data(from: url)
        let statusCode = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
        XCTAssertEqual(statusCode, 200, "The isolated API did not return its seeded Feed")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try XCTUnwrap(json["data"] as? [[String: Any]])
        let first = try XCTUnwrap(items.first)
        return try XCTUnwrap(first["publicSlug"] as? String)
    }

    private func createOwnedVersionFixture(title: String) async throws -> String {
        let workURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/works"))
        var workRequest = URLRequest(url: workURL)
        workRequest.httpMethod = "POST"
        workRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        workRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "title": title,
            "instruction": "Build a private version fixture",
            "creationMode": "original"
        ])
        let (workData, workResponse) = try await URLSession.shared.data(for: workRequest)
        XCTAssertEqual((workResponse as? HTTPURLResponse)?.statusCode, 201, "Could not create the owned version fixture")
        let workPayload = try XCTUnwrap(try JSONSerialization.jsonObject(with: workData) as? [String: Any])
        let work = try XCTUnwrap(workPayload["work"] as? [String: Any])
        let workID = try XCTUnwrap(work["id"] as? String)

        let generationURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/works/\(workID)/generations"))
        var generationRequest = URLRequest(url: generationURL)
        generationRequest.httpMethod = "POST"
        generationRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        generationRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "instruction": "Build a private version fixture",
            "assetIds": []
        ])
        let (generationData, generationResponse) = try await URLSession.shared.data(for: generationRequest)
        XCTAssertEqual((generationResponse as? HTTPURLResponse)?.statusCode, 202, "Could not start the owned version fixture")
        let generationPayload = try XCTUnwrap(try JSONSerialization.jsonObject(with: generationData) as? [String: Any])
        let generation = try XCTUnwrap(generationPayload["generation"] as? [String: Any])
        let generationID = try XCTUnwrap(generation["id"] as? String)

        let statusURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/generations/\(generationID)"))
        for _ in 0..<60 {
            let (statusData, statusResponse) = try await URLSession.shared.data(from: statusURL)
            XCTAssertEqual((statusResponse as? HTTPURLResponse)?.statusCode, 200, "Could not read the version fixture generation")
            let statusPayload = try XCTUnwrap(try JSONSerialization.jsonObject(with: statusData) as? [String: Any])
            let statusGeneration = try XCTUnwrap(statusPayload["generation"] as? [String: Any])
            if let stage = statusGeneration["stage"] as? String, ["succeeded", "fallback_ready", "failed", "cancelled"].contains(stage) {
                XCTAssertEqual(stage, "succeeded", "Version fixture did not reach a usable candidate")
                return workID
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw FixtureError.generationTimedOut
    }

    private func createOwnedHistoricalVersionFixture(title: String) async throws -> String {
        let workID = try await createOwnedVersionFixture(title: title)
        let generationURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/works/\(workID)/generations"))
        var generationRequest = URLRequest(url: generationURL)
        generationRequest.httpMethod = "POST"
        generationRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        generationRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "instruction": "Build a revised current candidate after the private historical fixture",
            "assetIds": []
        ])
        let (generationData, generationResponse) = try await URLSession.shared.data(for: generationRequest)
        XCTAssertEqual((generationResponse as? HTTPURLResponse)?.statusCode, 202, "Could not create the newer fixture candidate")
        let generationPayload = try XCTUnwrap(try JSONSerialization.jsonObject(with: generationData) as? [String: Any])
        let generation = try XCTUnwrap(generationPayload["generation"] as? [String: Any])
        let generationID = try XCTUnwrap(generation["id"] as? String)

        let statusURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/generations/\(generationID)"))
        for _ in 0..<60 {
            let (statusData, statusResponse) = try await URLSession.shared.data(from: statusURL)
            XCTAssertEqual((statusResponse as? HTTPURLResponse)?.statusCode, 200, "Could not read the newer fixture generation")
            let statusPayload = try XCTUnwrap(try JSONSerialization.jsonObject(with: statusData) as? [String: Any])
            let statusGeneration = try XCTUnwrap(statusPayload["generation"] as? [String: Any])
            if let stage = statusGeneration["stage"] as? String, ["succeeded", "fallback_ready", "failed", "cancelled"].contains(stage) {
                XCTAssertEqual(stage, "succeeded", "Historical preview fixture did not create a usable current candidate")
                return workID
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw FixtureError.generationTimedOut
    }

    private func createOwnedPublishedWorkFixture(title: String) async throws -> String {
        let workID = try await createOwnedVersionFixture(title: title)
        let reviewURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/works/\(workID)/content-review-requests"))
        var reviewRequest = URLRequest(url: reviewURL)
        reviewRequest.httpMethod = "POST"
        let (_, reviewResponse) = try await URLSession.shared.data(for: reviewRequest)
        XCTAssertEqual((reviewResponse as? HTTPURLResponse)?.statusCode, 200, "Could not submit the public-share fixture for content review")

        let moderationURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/admin/works/\(workID)"))
        var moderationRequest = URLRequest(url: moderationURL)
        moderationRequest.httpMethod = "PATCH"
        moderationRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        moderationRequest.setValue("local-operator", forHTTPHeaderField: "X-Pulse-Admin")
        moderationRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "contentReviewStatus": "approved",
            "ageRating": "4+",
            "reason": "Approve a fixture used to verify sharing from current live work details."
        ])
        let (_, moderationResponse) = try await URLSession.shared.data(for: moderationRequest)
        XCTAssertEqual((moderationResponse as? HTTPURLResponse)?.statusCode, 200, "Could not approve the public-share fixture")

        let publishURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/works/\(workID)/publish"))
        var publishRequest = URLRequest(url: publishURL)
        publishRequest.httpMethod = "POST"
        let (_, publishResponse) = try await URLSession.shared.data(for: publishRequest)
        XCTAssertEqual((publishResponse as? HTTPURLResponse)?.statusCode, 200, "Could not publish the public-share fixture")
        return workID
    }

    private func createOwnedRemixFixture(title: String) async throws -> String {
        let parentID = try await seededWorkID()
        let workURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/works"))
        var request = URLRequest(url: workURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "title": title,
            "instruction": "Make a verified original navigation fixture",
            "creationMode": "remix",
            "parentWorkId": parentID
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201, "Could not create the owned Remix fixture")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let work = try XCTUnwrap(payload["work"] as? [String: Any])
        return try XCTUnwrap(work["id"] as? String)
    }

    private func createOwnedRevokedWorkFixture(title: String) async throws -> String {
        let workID = try await createOwnedVersionFixture(title: title)
        let reviewURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/works/\(workID)/content-review-requests"))
        var reviewRequest = URLRequest(url: reviewURL)
        reviewRequest.httpMethod = "POST"
        let (_, reviewResponse) = try await URLSession.shared.data(for: reviewRequest)
        XCTAssertEqual((reviewResponse as? HTTPURLResponse)?.statusCode, 200, "Could not submit the revoked-link fixture for content review")

        let moderationURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/admin/works/\(workID)"))
        var moderationRequest = URLRequest(url: moderationURL)
        moderationRequest.httpMethod = "PATCH"
        moderationRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        moderationRequest.setValue("local-operator", forHTTPHeaderField: "X-Pulse-Admin")
        moderationRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "contentReviewStatus": "approved",
            "ageRating": "4+",
            "reason": "Approve a fixture used to verify the creator lifecycle UI."
        ])
        let (_, moderationResponse) = try await URLSession.shared.data(for: moderationRequest)
        XCTAssertEqual((moderationResponse as? HTTPURLResponse)?.statusCode, 200, "Could not approve the revoked-link fixture")

        let publishURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/works/\(workID)/publish"))
        var publishRequest = URLRequest(url: publishURL)
        publishRequest.httpMethod = "POST"
        let (_, publishResponse) = try await URLSession.shared.data(for: publishRequest)
        XCTAssertEqual((publishResponse as? HTTPURLResponse)?.statusCode, 200, "Could not publish the revoked-link fixture")

        let revokeURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/works/\(workID)/unpublish"))
        var revokeRequest = URLRequest(url: revokeURL)
        revokeRequest.httpMethod = "POST"
        let (revokeData, revokeResponse) = try await URLSession.shared.data(for: revokeRequest)
        XCTAssertEqual((revokeResponse as? HTTPURLResponse)?.statusCode, 200, "Could not revoke the fixture link")
        let revokePayload = try XCTUnwrap(try JSONSerialization.jsonObject(with: revokeData) as? [String: Any])
        let revokedWork = try XCTUnwrap(revokePayload["work"] as? [String: Any])
        XCTAssertNotNil(revokedWork["publicLinkRevokedAt"] as? String, "The fixture did not retain its creator-revocation marker")
        return workID
    }

    private enum FixtureError: Error {
        case generationTimedOut
    }

    private func seedHiddenComment(workID: String, body: String) async throws {
        let commentURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/works/\(workID)/comments"))
        var createRequest = URLRequest(url: commentURL)
        createRequest.httpMethod = "POST"
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createRequest.httpBody = try JSONSerialization.data(withJSONObject: ["score": 3, "body": body])
        let (createdData, createdResponse) = try await URLSession.shared.data(for: createRequest)
        XCTAssertEqual((createdResponse as? HTTPURLResponse)?.statusCode, 201, "Could not create the comment fixture")
        let createdPayload = try XCTUnwrap(try JSONSerialization.jsonObject(with: createdData) as? [String: Any])
        let createdComment = try XCTUnwrap(createdPayload["comment"] as? [String: Any])
        let commentID = try XCTUnwrap(createdComment["id"] as? String)

        let moderationURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/admin/comments/\(commentID)"))
        var moderationRequest = URLRequest(url: moderationURL)
        moderationRequest.httpMethod = "PATCH"
        moderationRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        moderationRequest.setValue("local-operator", forHTTPHeaderField: "X-Pulse-Admin")
        moderationRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "status": "hidden",
            "reason": "Fixture moderation decision for the hidden-state UI regression."
        ])
        let (moderatedData, moderatedResponse) = try await URLSession.shared.data(for: moderationRequest)
        XCTAssertEqual((moderatedResponse as? HTTPURLResponse)?.statusCode, 200, "Could not hide the comment fixture")
        let moderatedPayload = try XCTUnwrap(try JSONSerialization.jsonObject(with: moderatedData) as? [String: Any])
        let moderatedComment = try XCTUnwrap(moderatedPayload["comment"] as? [String: Any])
        XCTAssertEqual(moderatedComment["status"] as? String, "hidden", "Comment fixture did not enter the hidden state")
    }

    private func seedVisibleComments(workID: String, count: Int) async throws {
        let commentURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/works/\(workID)/comments"))
        for index in 1...count {
            var request = URLRequest(url: commentURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Different local principals keep this fixture below the per-user
            // anti-spam limit while still exercising one public thread.
            request.setValue("pagination-fixture-\(index)", forHTTPHeaderField: "X-Pulse-User")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "score": 5,
                "body": String(format: "Pagination comment %02d", index)
            ])
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201, "Could not create pagination fixture \(index)")
        }
    }

    private func seedReporterStatus(workID: String) async throws {
        let reportURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/reports"))
        var createRequest = URLRequest(url: reportURL)
        createRequest.httpMethod = "POST"
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "targetType": "work",
            "targetId": workID,
            "reason": "Unsafe behavior"
        ])
        let (createdData, createdResponse) = try await URLSession.shared.data(for: createRequest)
        XCTAssertEqual((createdResponse as? HTTPURLResponse)?.statusCode, 201, "Could not create the reporter-history fixture")
        let createdPayload = try XCTUnwrap(try JSONSerialization.jsonObject(with: createdData) as? [String: Any])
        let report = try XCTUnwrap(createdPayload["report"] as? [String: Any])
        let reportID = try XCTUnwrap(report["id"] as? String)

        let moderationURL = try XCTUnwrap(URL(string: "\(isolatedAPIBaseURL)/admin/reports/\(reportID)"))
        var moderationRequest = URLRequest(url: moderationURL)
        moderationRequest.httpMethod = "PATCH"
        moderationRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        moderationRequest.setValue("local-operator", forHTTPHeaderField: "X-Pulse-Admin")
        moderationRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "status": "investigating"
        ])
        let (_, moderationResponse) = try await URLSession.shared.data(for: moderationRequest)
        XCTAssertEqual((moderationResponse as? HTTPURLResponse)?.statusCode, 200, "Could not place the reporter-history fixture under review")
    }
}
