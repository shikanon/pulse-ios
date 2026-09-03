import Foundation
import XCTest

@MainActor
final class CoreUserJourneyUITests: XCTestCase {
    private let apiBaseURL = "http://127.0.0.1:18787/v1"
    private let testAccount = "pulse.e2e"
    private let fixtureCreator = "pulse.fixture.creator"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testBrowseLikeAndCommentCoreJourney() async throws {
        let fixtures = try await feedFixtures(limit: 2)
        let first = try XCTUnwrap(fixtures.first)
        let second = try XCTUnwrap(fixtures.dropFirst().first)
        let app = launchApp()

        XCTAssertTrue(app.staticTexts[first.title].waitForExistence(timeout: 12), "The first live Feed card did not render")
        XCTAssertTrue(app.staticTexts["by @\(first.creator)"].exists, "The Feed omitted creator attribution")
        XCTAssertFalse(app.staticTexts["Couldn’t load Pulse. Check your connection and try again."].exists)

        let like = app.buttons["Like this work"].firstMatch
        XCTAssertTrue(like.waitForExistence(timeout: 5), "The active Feed card did not expose Like")
        let previousLikes = integerPrefix(from: like.value as? String)
        like.tap()

        let unlike = app.buttons["Unlike this work"].firstMatch
        XCTAssertTrue(unlike.waitForExistence(timeout: 8), "Like did not change to the persisted Unlike state")
        XCTAssertEqual(integerPrefix(from: unlike.value as? String), previousLikes + 1, "The visible Like count did not increment")

        let comments = app.buttons["Comments"].firstMatch
        XCTAssertTrue(comments.waitForExistence(timeout: 5), "The active Feed card did not expose Comments")
        comments.tap()

        let comment = "Core journey comment \(UUID().uuidString.prefix(8))"
        let input = app.textFields["community.comment.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 8), "The comment composer did not open")
        input.tap()
        input.typeText(comment)
        let submit = app.buttons["community.comment.submit"]
        XCTAssertTrue(submit.isEnabled, "The Post action stayed disabled after valid input")
        submit.tap()
        XCTAssertTrue(app.staticTexts[comment].waitForExistence(timeout: 8), "The new comment did not appear in the conversation")

        app.buttons["Done"].tap()
        for _ in 0..<3 where !app.staticTexts[second.title].isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts[second.title].waitForExistence(timeout: 8), "Paging the Feed did not reveal the next work")
        assertHealthyForeground(app)
        attachScreenshot(named: "core-feed-like-comment", app: app)
    }

    func testPlayAnotherCreatorsGeneratedWork() async throws {
        let title = "Other creator artifact \(UUID().uuidString.prefix(8))"
        let instruction = "Build a tactile constellation for the shared-play regression"
        let fixture = try await createPublishedGeneratedWork(title: title, instruction: instruction, owner: fixtureCreator)
        let app = launchApp()

        XCTAssertTrue(app.staticTexts[fixture.title].waitForExistence(timeout: 12), "The generated work did not appear at the front of the Feed")
        XCTAssertTrue(app.staticTexts["by @\(fixture.creator)"].exists, "The work did not retain its other-creator attribution")
        XCTAssertNotEqual(fixture.creator, testAccount, "The shared-play fixture must belong to a different account")

        let player = app.webViews["published.artifact.player"]
        XCTAssertTrue(player.waitForExistence(timeout: 15), "The published work did not load its real Artifact player")
        let interact = player.buttons["Interact"]
        XCTAssertTrue(interact.waitForExistence(timeout: 10), "The generated Artifact did not expose its primary interaction")
        interact.tap()
        XCTAssertTrue(
            player.staticTexts["Interaction received — your local Pulse artifact is running."].waitForExistence(timeout: 8),
            "Playing another creator’s work produced no observable state change"
        )

        assertHealthyForeground(app)
        attachScreenshot(named: "core-play-other-generated-work", app: app)
    }

    func testGenerateReviewPublishAndPlayCoreJourney() async throws {
        let prompt = "Build a neon tap garden \(UUID().uuidString.prefix(8))"
        let app = launchApp()

        let create = app.buttons["Create an original app from one sentence"]
        XCTAssertTrue(create.waitForExistence(timeout: 12), "The primary Create entry did not render")
        create.tap()

        let promptEditor = app.textViews["creation.prompt"]
        XCTAssertTrue(promptEditor.waitForExistence(timeout: 5), "The one-sentence editor did not render")
        XCTAssertEqual(app.buttons["app.tab.create"].value as? String, "Selected", "The Create entry did not switch to the Create tab")
        promptEditor.tap()
        promptEditor.typeText(prompt)
        XCTAssertEqual(promptEditor.value as? String, prompt, "The editor did not retain the creation instruction")

        let generate = app.buttons["creation.generate"]
        XCTAssertTrue(generate.isEnabled, "Generate stayed disabled after a valid instruction")
        generate.tap()
        XCTAssertTrue(
            app.staticTexts["Your interactive app is ready"].waitForExistence(timeout: 45),
            "Deterministic generation did not pass its verification gates in time"
        )

        let previewPlayer = app.webViews["generation.artifact.player"]
        XCTAssertTrue(previewPlayer.waitForExistence(timeout: 15), "The private generated Artifact did not load in preview")
        let resultScroll = app.scrollViews
            .containing(.webView, identifier: "generation.artifact.player")
            .firstMatch
        XCTAssertTrue(resultScroll.waitForExistence(timeout: 5), "The generated result did not expose its own scroll container")
        let previewInteraction = previewPlayer.buttons["Interact"]
        XCTAssertTrue(previewInteraction.waitForExistence(timeout: 10), "The generated preview was not playable")
        XCTAssertTrue(
            bringIntoUnobscuredViewport(previewInteraction, in: resultScroll, app: app),
            "The generated preview interaction remained covered by navigation chrome"
        )
        let previewBeforeInteraction = app.screenshot().pngRepresentation
        previewInteraction.tap()
        XCTAssertEqual(app.buttons["app.tab.create"].value as? String, "Selected", "Playing the generated preview accidentally changed tabs")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNotEqual(
            app.screenshot().pngRepresentation,
            previewBeforeInteraction,
            "The generated preview did not produce an observable visual state change"
        )

        let requestReview = app.buttons["generation.request-content-review"]
        XCTAssertTrue(
            bringIntoUnobscuredViewport(requestReview, in: resultScroll, app: app),
            "The verified preview did not expose its content-review action"
        )
        requestReview.tap()

        let checkReview = app.buttons["generation.check-content-review"]
        XCTAssertTrue(checkReview.waitForExistence(timeout: 8), "Submitting review did not produce a clear queued state")
        let workID = try await ownedWorkID(matchingPrompt: prompt)
        try await approveWork(workID: workID)

        checkReview.tap()
        let publish = app.buttons["generation.publish"]
        XCTAssertTrue(publish.waitForExistence(timeout: 10), "An approved 4+ work did not become publishable")
        XCTAssertTrue(
            publish.isEnabled && bringIntoUnobscuredViewport(publish, in: resultScroll, app: app),
            "Publish was not actionable after approval"
        )
        publish.tap()

        let homeTab = app.buttons["app.tab.home"]
        let homeSelected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Selected"),
            object: homeTab
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [homeSelected], timeout: 15),
            .completed,
            "Publishing did not return to the Feed"
        )
        homeTab.tap()
        XCTAssertTrue(app.staticTexts[prompt].waitForExistence(timeout: 15), "Publishing did not return to the new live Feed card")
        XCTAssertTrue(app.staticTexts["by @\(testAccount)"].exists, "The published work was not attributed to the test account")
        let publishedPlayer = app.webViews["published.artifact.player"]
        XCTAssertTrue(publishedPlayer.waitForExistence(timeout: 15), "The published Artifact did not load back in the Feed")
        let publishedInteraction = publishedPlayer.buttons["Interact"]
        XCTAssertTrue(publishedInteraction.waitForExistence(timeout: 10), "The published Artifact lost its primary interaction")
        publishedInteraction.tap()
        XCTAssertTrue(
            publishedPlayer.staticTexts["Interaction received — your local Pulse artifact is running."].waitForExistence(timeout: 8),
            "The published generated work did not remain playable"
        )

        assertHealthyForeground(app)
        attachScreenshot(named: "core-generate-review-publish-play", app: app)
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_API_BASE_URL"] = apiBaseURL
        app.launchEnvironment["PULSE_UI_TEST_USER"] = testAccount
        app.launch()
        return app
    }

    private func bringIntoUnobscuredViewport(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        app: XCUIApplication
    ) -> Bool {
        let topBoundary = app.navigationBars["Create"].frame.maxY + 8
        let bottomBoundary = app.buttons["app.tab.create"].frame.minY - 8

        for _ in 0..<16 {
            let frame = element.frame
            if frame.minY >= topBoundary, frame.maxY <= bottomBoundary, element.isHittable {
                return true
            }
            if frame.maxY > bottomBoundary {
                drag(scrollView, fromY: 0.72, toY: 0.48)
            } else if frame.minY < topBoundary {
                drag(scrollView, fromY: 0.32, toY: 0.56)
            } else {
                return false
            }
        }
        return false
    }

    private func drag(_ scrollView: XCUIElement, fromY: CGFloat, toY: CGFloat) {
        let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: fromY))
        let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: toY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func assertHealthyForeground(_ app: XCUIApplication) {
        XCTAssertEqual(app.state, .runningForeground, "Pulse left the foreground during the core journey")
        XCTAssertFalse(app.alerts.firstMatch.exists, "A blocking system or product alert remained on screen")
        XCTAssertFalse(app.descendants(matching: .any)["artifact.player.error"].exists, "The active Artifact fell back to an error state")
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func integerPrefix(from value: String?) -> Int {
        Int((value ?? "0").prefix { $0.isNumber }) ?? 0
    }

    private func feedFixtures(limit: Int) async throws -> [WorkFixture] {
        let payload = try await requestJSON(path: "feed?limit=\(limit)", expectedStatus: 200)
        let data = try XCTUnwrap(payload["data"] as? [[String: Any]])
        return try data.map { item in
            WorkFixture(
                id: try XCTUnwrap(item["id"] as? String),
                title: try XCTUnwrap(item["title"] as? String),
                creator: try XCTUnwrap(item["creator"] as? String)
            )
        }
    }

    private func createPublishedGeneratedWork(title: String, instruction: String, owner: String) async throws -> WorkFixture {
        let created = try await requestJSON(
            path: "works",
            method: "POST",
            user: owner,
            idempotencyKey: "core-work-\(UUID().uuidString)",
            body: ["title": title, "instruction": instruction, "creationMode": "original"],
            expectedStatus: 201
        )
        let work = try XCTUnwrap(created["work"] as? [String: Any])
        let workID = try XCTUnwrap(work["id"] as? String)

        let started = try await requestJSON(
            path: "works/\(workID)/generations",
            method: "POST",
            user: owner,
            idempotencyKey: "core-generation-\(UUID().uuidString)",
            body: ["instruction": instruction, "assetIds": []],
            expectedStatus: 202
        )
        let generation = try XCTUnwrap(started["generation"] as? [String: Any])
        let generationID = try XCTUnwrap(generation["id"] as? String)
        try await waitForSuccessfulGeneration(id: generationID, owner: owner)

        _ = try await requestJSON(
            path: "works/\(workID)/content-review-requests",
            method: "POST",
            user: owner,
            expectedStatus: 200
        )
        try await approveWork(workID: workID)
        let published = try await requestJSON(path: "works/\(workID)/publish", method: "POST", user: owner, expectedStatus: 200)
        let publishedWork = try XCTUnwrap(published["work"] as? [String: Any])
        return WorkFixture(
            id: workID,
            title: try XCTUnwrap(publishedWork["title"] as? String),
            creator: try XCTUnwrap(publishedWork["creator"] as? String)
        )
    }

    private func waitForSuccessfulGeneration(id: String, owner: String) async throws {
        for _ in 0..<120 {
            let payload = try await requestJSON(path: "generations/\(id)", user: owner, expectedStatus: 200)
            let generation = try XCTUnwrap(payload["generation"] as? [String: Any])
            let stage = try XCTUnwrap(generation["stage"] as? String)
            if ["succeeded", "fallback_ready", "failed", "cancelled"].contains(stage) {
                XCTAssertEqual(stage, "succeeded", "The generated fixture did not reach a verified terminal state")
                XCTAssertEqual(generation["verificationGrade"] as? String, "verified")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The generated fixture timed out")
        throw FixtureError.generationTimedOut
    }

    private func ownedWorkID(matchingPrompt prompt: String) async throws -> String {
        let payload = try await requestJSON(path: "me/works", user: testAccount, expectedStatus: 200)
        let works = try XCTUnwrap(payload["data"] as? [[String: Any]])
        let work = try XCTUnwrap(works.first { $0["prompt"] as? String == prompt }, "The generated work was not owned by the test account")
        return try XCTUnwrap(work["id"] as? String)
    }

    private func approveWork(workID: String) async throws {
        _ = try await requestJSON(
            path: "admin/works/\(workID)",
            method: "PATCH",
            user: "pulse.e2e.operator",
            admin: "pulse.e2e.operator",
            body: [
                "contentReviewStatus": "approved",
                "ageRating": "4+",
                "reason": "Approve the isolated core-user-journey fixture."
            ],
            expectedStatus: 200
        )
    }

    private func requestJSON(
        path: String,
        method: String = "GET",
        user: String? = nil,
        admin: String? = nil,
        idempotencyKey: String? = nil,
        body: [String: Any]? = nil,
        expectedStatus: Int
    ) async throws -> [String: Any] {
        let url = try XCTUnwrap(URL(string: "\(apiBaseURL)/\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let user { request.setValue(user, forHTTPHeaderField: "X-Pulse-User") }
        if let admin { request.setValue(admin, forHTTPHeaderField: "X-Pulse-Admin") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
        guard statusCode == expectedStatus else {
            XCTFail("\(method) \(path) returned \(statusCode), expected \(expectedStatus): \(String(data: data, encoding: .utf8) ?? "<non-UTF8>")")
            throw FixtureError.unexpectedStatus
        }
        guard !data.isEmpty else { return [:] }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private struct WorkFixture {
        let id: String
        let title: String
        let creator: String
    }

    private enum FixtureError: Error {
        case generationTimedOut
        case unexpectedStatus
    }
}
