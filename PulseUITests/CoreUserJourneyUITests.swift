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

        XCTAssertTrue(app.staticTexts[first.theme].waitForExistence(timeout: 12), "The first live Feed card did not render its introduction")
        XCTAssertTrue(app.staticTexts["@\(first.creator)"].exists, "The Feed omitted creator attribution")
        XCTAssertFalse(app.staticTexts["Couldn’t load Pulse. Check your connection and try again."].exists)
        XCTAssertFalse(app.staticTexts["Pulse"].exists, "The Home card still consumed space with a redundant Pulse logo")
        assertFeedChromeDoesNotCoverInteraction(in: app)

        let summary = activeFeedSummary(in: app)
        let details = summary.buttons["feed.work-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 3), "The Feed did not expose work details")
        details.tap()
        XCTAssertTrue(app.navigationBars["Work details"].waitForExistence(timeout: 5), "The work introduction did not open")
        XCTAssertTrue(app.staticTexts["@\(first.creator)"].exists, "Work details lost the creator identity")
        app.buttons["Done"].tap()

        let like = summary.buttons["Like this work"]
        let unlike = summary.buttons["Unlike this work"]
        if unlike.exists {
            let previousLikes = integerPrefix(from: unlike.value as? String)
            unlike.tap()
            XCTAssertTrue(like.waitForExistence(timeout: 8), "Unlike did not change to the persisted Like state")
            XCTAssertEqual(integerPrefix(from: like.value as? String), max(0, previousLikes - 1), "The visible Like count did not decrement")
        } else {
            XCTAssertTrue(like.waitForExistence(timeout: 5), "The active Feed card did not expose Like")
            let previousLikes = integerPrefix(from: like.value as? String)
            like.tap()
            XCTAssertTrue(unlike.waitForExistence(timeout: 8), "Like did not change to the persisted Unlike state")
            XCTAssertEqual(integerPrefix(from: unlike.value as? String), previousLikes + 1, "The visible Like count did not increment")
        }

        let comments = summary.buttons["Comments"]
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
        let firstPlayer = activeFeedInteraction(in: app).webViews["published.artifact.player"]
        for _ in 0..<3 where !app.staticTexts[second.theme].isHittable {
            if firstPlayer.exists { firstPlayer.swipeUp() } else { app.swipeUp() }
        }
        XCTAssertTrue(app.staticTexts[second.theme].isHittable, "Paging from an interactive Artifact did not reveal the next Feed work")
        assertHealthyForeground(app)
        attachScreenshot(named: "core-feed-like-comment", app: app)
    }

    func testGeneratedSnakeIsAPlayableArtifact() throws {
        let app = launchApp()
        app.buttons["app.tab.create"].tap()

        let prompt = app.textViews["creation.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 8), "The creation prompt did not render")
        assertCompactResourceActions(in: app)
        attachScreenshot(named: "core-create-compact-resources", app: app)
        prompt.tap()
        prompt.typeText("生成一个真正可玩的贪食蛇游戏")
        app.buttons["creation.generate"].tap()

        XCTAssertTrue(app.staticTexts["Your interactive app is ready"].waitForExistence(timeout: 45))
        let player = app.webViews["generation.artifact.player"]
        XCTAssertTrue(player.waitForExistence(timeout: 15), "The snake Artifact did not load")
        XCTAssertGreaterThanOrEqual(player.frame.width, app.frame.width - 4, "The generated player did not use the same full-width surface as Home")
        let readyTitle = app.staticTexts["Your interactive app is ready"]
        XCTAssertGreaterThanOrEqual(
            player.frame.minY,
            readyTitle.frame.maxY,
            "The generated player covered the result heading"
        )
        attachScreenshot(named: "core-create-full-width-preview", app: app)
        let resultScroll = app.scrollViews
            .containing(.webView, identifier: "generation.artifact.player")
            .firstMatch
        XCTAssertTrue(resultScroll.waitForExistence(timeout: 5), "The generated result did not expose its own scroll container")
        XCTAssertGreaterThanOrEqual(
            player.frame.height,
            resultScroll.frame.height - 132,
            "The generated player did not use Home’s shared interaction-height budget"
        )
        let start = player.buttons["START"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "The generated result was a placeholder instead of a playable snake game")
        XCTAssertTrue(bringIntoUnobscuredViewport(start, in: resultScroll, app: app), "The larger generated player kept Start outside the usable viewport")
        assertPlayableControlsAreContained(in: player, app: app, startLabel: "START", pauseLabel: "PAUSE")
        let before = app.screenshot().pngRepresentation
        start.tap()
        XCTAssertTrue(player.buttons["PAUSE"].waitForExistence(timeout: 5), "Starting the snake game did not expose pause control")
        assertPlayableControlsAreContained(in: player, app: app, startLabel: "RESTART", pauseLabel: "PAUSE")
        let pause = player.buttons["PAUSE"]
        pause.tap()
        XCTAssertTrue(player.buttons["RESUME"].waitForExistence(timeout: 5), "Pause was covered or did not expose Resume")
        player.buttons["RESUME"].tap()
        XCTAssertTrue(player.buttons["PAUSE"].waitForExistence(timeout: 5), "Resume was covered or did not return the game to its running state")
        let down = player.buttons["Down"]
        XCTAssertTrue(down.waitForExistence(timeout: 5), "The generated snake game did not expose touch direction controls")
        XCTAssertTrue(bringIntoUnobscuredViewport(down, in: resultScroll, app: app), "The larger generated player kept direction controls outside the usable viewport")
        down.tap()
        Thread.sleep(forTimeInterval: 0.45)
        XCTAssertNotEqual(app.screenshot().pngRepresentation, before, "The generated snake board did not change after play input")
        assertHealthyForeground(app)
        attachScreenshot(named: "core-generated-playable-snake", app: app)
    }

    func testSettingsSwitchBetweenEnglishAndChinese() throws {
        let app = launchApp()
        app.buttons["app.tab.profile"].tap()
        let settings = app.buttons["profile.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "Profile did not expose Settings")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings did not start in English")

        let chinese = app.buttons["简体中文"]
        XCTAssertTrue(chinese.waitForExistence(timeout: 5), "Settings did not expose Simplified Chinese")
        chinese.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5), "Changing language did not update Settings immediately")
        XCTAssertEqual(app.buttons["app.tab.home"].label, "主页", "The app navigation did not switch to Chinese")

        let english = app.buttons["English"]
        XCTAssertTrue(english.waitForExistence(timeout: 5), "The language control did not remain actionable after switching")
        english.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Changing back to English did not apply immediately")
    }

    func testPlayAnotherCreatorsGeneratedWork() async throws {
        let title = "Other creator artifact \(UUID().uuidString.prefix(8))"
        let instruction = "生成一个真正可玩的贪食蛇游戏"
        let fixture = try await createPublishedGeneratedWork(title: title, instruction: instruction, owner: fixtureCreator)
        let app = launchApp()

        XCTAssertTrue(app.staticTexts[fixture.theme].waitForExistence(timeout: 12), "The generated work did not appear at the front of the Feed")
        XCTAssertTrue(app.staticTexts["@\(fixture.creator)"].exists, "The work did not retain its other-creator attribution")
        XCTAssertNotEqual(fixture.creator, testAccount, "The shared-play fixture must belong to a different account")

        let player = activeFeedInteraction(in: app).webViews["published.artifact.player"]
        XCTAssertTrue(player.waitForExistence(timeout: 15), "The published work did not load its real Artifact player")
        assertFeedChromeDoesNotCoverInteraction(in: app)
        let start = player.buttons["START"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "The other creator’s generated snake did not expose Start")
        assertPlayableControlsAreContained(in: player, app: app, startLabel: "START", pauseLabel: "PAUSE")
        start.tap()
        assertPlayableControlsAreContained(in: player, app: app, startLabel: "RESTART", pauseLabel: "PAUSE")
        let down = player.buttons["Down"]
        XCTAssertTrue(down.waitForExistence(timeout: 5), "The other creator’s generated snake did not expose direction controls")
        let boundary = app.descendants(matching: .any)["feed.interaction-boundary"].firstMatch
        XCTAssertLessThanOrEqual(
            down.frame.maxY,
            boundary.frame.maxY - 4,
            "Home chrome still clips the generated game’s lower direction controls"
        )
        let beforeDirection = app.screenshot().pngRepresentation
        down.tap()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertNotEqual(app.screenshot().pngRepresentation, beforeDirection, "Playing another creator’s snake produced no observable state change")

        assertHealthyForeground(app)
        attachScreenshot(named: "core-play-other-generated-work", app: app)
    }

    func testGeneratePublishAndPlayCoreJourney() async throws {
        let prompt = "Build a neon tap garden \(UUID().uuidString.prefix(8))"
        let app = launchApp()

        let create = app.buttons["Create an original app from one sentence"]
        XCTAssertTrue(create.waitForExistence(timeout: 12), "The primary Create entry did not render")
        create.tap()

        let promptEditor = app.textViews["creation.prompt"]
        XCTAssertTrue(promptEditor.waitForExistence(timeout: 5), "The one-sentence editor did not render")
        assertCompactResourceActions(in: app)
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
        XCTAssertGreaterThanOrEqual(previewPlayer.frame.width, app.frame.width - 4, "Create preview did not align to Home’s full-width interaction surface")
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

        let publish = app.buttons["generation.publish"]
        XCTAssertTrue(publish.waitForExistence(timeout: 10), "A verified work did not become immediately publishable")
        XCTAssertFalse(app.buttons["generation.request-content-review"].exists, "The client still required pre-publication review")
        XCTAssertFalse(app.buttons["generation.check-content-review"].exists, "The client still exposed a pre-publication review queue")
        XCTAssertTrue(
            publish.isEnabled && bringIntoUnobscuredViewport(publish, in: resultScroll, app: app),
            "Publish was not actionable immediately after verification"
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
        XCTAssertTrue(app.staticTexts["@\(testAccount)"].waitForExistence(timeout: 15), "Publishing did not return to the new live Feed card")
        let publishedPlayer = activeFeedInteraction(in: app).webViews["published.artifact.player"]
        XCTAssertTrue(publishedPlayer.waitForExistence(timeout: 15), "The published Artifact did not load back in the Feed")
        let publishedInteraction = publishedPlayer.buttons["Interact"]
        XCTAssertTrue(publishedInteraction.waitForExistence(timeout: 10), "The published Artifact lost its primary interaction")
        publishedInteraction.tap()
        XCTAssertTrue(
            publishedPlayer.staticTexts["Interaction received — your local Pulse artifact is running."].waitForExistence(timeout: 8),
            "The published generated work did not remain playable"
        )

        assertHealthyForeground(app)
        attachScreenshot(named: "core-generate-publish-play", app: app)
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_API_BASE_URL"] = apiBaseURL
        app.launchEnvironment["PULSE_UI_TEST_USER"] = testAccount
        app.launchEnvironment["PULSE_ALLOW_DEMO_GENERATION"] = "1"
        app.launch()
        return app
    }

    private func bringIntoUnobscuredViewport(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        app: XCUIApplication
    ) -> Bool {
        let createNavigationBar = app.navigationBars["Create"]
        let topBoundary = createNavigationBar.exists ? createNavigationBar.frame.maxY + 8 : app.frame.minY + 60
        let bottomBoundary = app.buttons["app.tab.create"].frame.minY - 8

        for _ in 0..<16 {
            let frame = element.frame
            if frame.minY >= topBoundary, frame.maxY <= bottomBoundary {
                // WebKit descendants can report isHittable=false while their
                // frame is fully visible and XCUI can tap them normally. The
                // geometry is the stable regression contract here.
                return element.exists
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

    private func assertFeedChromeDoesNotCoverInteraction(in app: XCUIApplication) {
        let surface = activeFeedInteraction(in: app)
        let boundary = app.descendants(matching: .any)["feed.interaction-boundary"].firstMatch
        let summary = activeFeedSummary(in: app)
        XCTAssertTrue(surface.waitForExistence(timeout: 5), "The Feed did not expose its interaction surface")
        XCTAssertTrue(boundary.waitForExistence(timeout: 5), "The Feed did not expose its rendered interaction boundary")
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "The Feed did not expose its author and action panel")
        XCTAssertLessThanOrEqual(
            boundary.frame.maxY,
            summary.frame.minY + 2,
            "The author and action panel covered the interactive app"
        )

        let like = summary.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Like this work", "Unlike this work")
        ).firstMatch
        XCTAssertTrue(like.waitForExistence(timeout: 3), "The lower action row omitted Like")
        XCTAssertGreaterThanOrEqual(
            like.frame.minY,
            boundary.frame.maxY - 2,
            "The lower action row still covered the interactive app"
        )
        let selectedTab = app.buttons["app.tab.home"]
        XCTAssertLessThanOrEqual(
            summary.frame.maxY,
            selectedTab.frame.minY - 4,
            "The Feed action panel overlaps the floating tab bar: summary=\(summary.frame), tab=\(selectedTab.frame)"
        )
        XCTAssertLessThanOrEqual(
            selectedTab.frame.minY - summary.frame.maxY,
            24,
            "The Feed left excessive dead space between its actions and tab bar"
        )

        let safety = app.descendants(matching: .any)["feed.work-safety"].firstMatch
        let comments = summary.buttons["Comments"]
        let remix = summary.buttons["Remix this work"]
        let share = summary.buttons["Share this work"]
        let details = summary.buttons["feed.work-details"]
        let controls = [details, safety, like, comments, remix, share]
        controls.forEach { control in
            XCTAssertTrue(control.exists, "The Feed summary omitted an expected action")
            XCTAssertGreaterThanOrEqual(control.frame.minX, summary.frame.minX - 1, "A Feed action escaped the summary horizontally")
            XCTAssertLessThanOrEqual(control.frame.maxX, summary.frame.maxX + 1, "A Feed action escaped the summary horizontally")
            XCTAssertGreaterThanOrEqual(control.frame.minY, summary.frame.minY - 1, "A Feed action escaped the summary vertically")
            XCTAssertLessThanOrEqual(control.frame.maxY, summary.frame.maxY + 1, "A Feed action escaped the summary vertically")
            XCTAssertLessThanOrEqual(control.frame.maxY, selectedTab.frame.minY - 4, "A Feed action is covered by the tab bar")
        }
        assertFramesDoNotOverlap(controls.map(\.frame), context: "Feed summary actions")

        let tabs = [
            app.buttons["app.tab.home"],
            app.buttons["app.tab.create"],
            app.buttons["app.tab.profile"]
        ]
        assertFramesDoNotOverlap(tabs.map(\.frame), context: "App tab buttons")
    }

    private func assertPlayableControlsAreContained(
        in player: XCUIElement,
        app: XCUIApplication,
        startLabel: String,
        pauseLabel: String
    ) {
        let labels = [startLabel, pauseLabel, "Up", "Left", "Down", "Right"]
        let controls = labels.map { player.buttons[$0] }
        let tabTop = app.buttons["app.tab.create"].frame.minY
        let visibleBottom = min(player.frame.maxY, tabTop - 4)

        for (label, control) in zip(labels, controls) {
            XCTAssertTrue(control.waitForExistence(timeout: 5), "The generated app omitted the \(label) control")
            XCTAssertGreaterThanOrEqual(control.frame.minX, player.frame.minX - 1, "\(label) escaped the player horizontally")
            XCTAssertLessThanOrEqual(control.frame.maxX, player.frame.maxX + 1, "\(label) escaped the player horizontally")
            XCTAssertGreaterThanOrEqual(control.frame.minY, player.frame.minY - 1, "\(label) escaped the player vertically")
            XCTAssertLessThanOrEqual(control.frame.maxY, visibleBottom, "\(label) is clipped or covered by app chrome")
        }
        assertFramesDoNotOverlap(controls.map(\.frame), context: "Generated app controls")
    }

    private func assertFramesDoNotOverlap(_ frames: [CGRect], context: String) {
        for leftIndex in frames.indices {
            for rightIndex in frames.indices where rightIndex > leftIndex {
                let overlap = frames[leftIndex].intersection(frames[rightIndex])
                XCTAssertTrue(
                    overlap.isNull || overlap.width <= 1 || overlap.height <= 1,
                    "\(context) overlap: \(frames[leftIndex]) and \(frames[rightIndex])"
                )
            }
        }
    }

    private func assertCompactResourceActions(in app: XCUIApplication) {
        let library = app.buttons["creation.resource-library"]
        let media = app.buttons["creation.upload-media"]
        let bgm = app.buttons["creation.upload-bgm"]
        XCTAssertTrue(library.waitForExistence(timeout: 5), "Create omitted the resource library action")
        XCTAssertTrue(media.waitForExistence(timeout: 5), "Create omitted the media action")
        XCTAssertTrue(bgm.waitForExistence(timeout: 5), "Create omitted the BGM action")
        XCTAssertLessThanOrEqual(abs(library.frame.midY - media.frame.midY), 3, "Library and Media were not placed on one compact row")
        XCTAssertLessThanOrEqual(abs(media.frame.midY - bgm.frame.midY), 3, "Media and BGM were not placed on one compact row")
        XCTAssertLessThan(library.frame.midX, media.frame.midX)
        XCTAssertLessThan(media.frame.midX, bgm.frame.midX)
        XCTAssertLessThanOrEqual(bgm.frame.maxX, app.frame.maxX - 16, "The compact BGM action was clipped at the trailing edge")
    }

    private func activeFeedInteraction(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["feed.interaction-surface"].firstMatch
    }

    private func activeFeedSummary(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["feed.summary-panel"].firstMatch
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
                creator: try XCTUnwrap(item["creator"] as? String),
                theme: try XCTUnwrap(item["theme"] as? String)
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

        let published = try await requestJSON(path: "works/\(workID)/publish", method: "POST", user: owner, expectedStatus: 200)
        let publishedWork = try XCTUnwrap(published["work"] as? [String: Any])
        return WorkFixture(
            id: workID,
            title: try XCTUnwrap(publishedWork["title"] as? String),
            creator: try XCTUnwrap(publishedWork["creator"] as? String),
            theme: try XCTUnwrap(publishedWork["theme"] as? String)
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
        let theme: String
    }

    private enum FixtureError: Error {
        case generationTimedOut
        case unexpectedStatus
    }
}
