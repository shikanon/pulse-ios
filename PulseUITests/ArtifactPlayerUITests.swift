import XCTest

final class ArtifactPlayerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPublishedArtifactLoadsAndRespondsToGameControls() throws {
        let app = XCUIApplication()
        app.launch()

        let player = app.webViews["published.artifact.player"]
        XCTAssertTrue(player.waitForExistence(timeout: 15), "Feed 没有加载已发布作品的 Artifact Player")

        let start = player.buttons["START"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "真实 Artifact 没有暴露游戏开始控件")
        let beforeStart = app.screenshot().pngRepresentation
        start.tap()
        Thread.sleep(forTimeInterval: 0.2)
        let afterStart = app.screenshot().pngRepresentation
        XCTAssertNotEqual(afterStart, beforeStart, "点击 START 后游戏画面没有发生变化")

        let pause = player.buttons["PAUSE"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "真实 Artifact 没有暴露暂停控件")
        pause.tap()
        let resume = player.buttons["RESUME"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "暂停后没有进入可恢复状态")
        resume.tap()

        let down = player.buttons["Down"]
        XCTAssertTrue(down.waitForExistence(timeout: 5), "真实 Artifact 没有暴露触控方向键")
        down.tap()
        Thread.sleep(forTimeInterval: 0.4)
        let afterDirection = app.screenshot().pngRepresentation
        XCTAssertNotEqual(afterDirection, afterStart, "点击方向键后游戏画面没有继续变化")

        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "pulse-artifact-player-real-snake"
        evidence.lifetime = .keepAlways
        add(evidence)
    }
}
