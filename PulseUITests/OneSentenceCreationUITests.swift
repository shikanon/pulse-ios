import XCTest

final class OneSentenceCreationUITests: XCTestCase {
    private let prompt = "生成疯狂版本的贪吃蛇"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreatePublishAndPlayCrazySnake() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_ALLOW_DEMO_GENERATION"] = "1"
        app.launch()

        let createTab = app.buttons["Create an original app from one sentence"]
        XCTAssertTrue(createTab.waitForExistence(timeout: 10), "底部导航没有出现一句话创作入口")
        createTab.tap()

        let promptEditor = app.textViews["creation.prompt"]
        XCTAssertTrue(promptEditor.waitForExistence(timeout: 5), "没有找到一句话创作输入框")
        promptEditor.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        promptEditor.typeText(prompt)
        XCTAssertEqual(promptEditor.value as? String, prompt, "输入框没有保存指定的中文创作指令")

        let generateButton = app.buttons["creation.generate"]
        XCTAssertTrue(generateButton.isEnabled, "输入指令后生成按钮仍不可用")
        generateButton.tap()

        XCTAssertTrue(
            app.staticTexts["Your interactive app is ready"].waitForExistence(timeout: 900),
            "生成任务没有在超时前通过验证并进入预览"
        )

        let previewPlayer = app.webViews["generation.artifact.player"]
        XCTAssertTrue(previewPlayer.waitForExistence(timeout: 30), "生成结果没有加载真实 Artifact Player")
        assertSnakeGameIsPlayable(in: previewPlayer, app: app, context: "发布前预览")

        let publishButton = app.buttons["generation.publish"]
        XCTAssertTrue(publishButton.isEnabled, "生成成功后发布按钮不可用")
        publishButton.tap()

        XCTAssertTrue(app.staticTexts[prompt].waitForExistence(timeout: 15), "发布后 Feed 没有显示本次创作")

        let publishedPlayer = app.webViews["published.artifact.player"]
        XCTAssertTrue(publishedPlayer.waitForExistence(timeout: 15), "已发布作品没有加载真实 Artifact Player")
        assertSnakeGameIsPlayable(in: publishedPlayer, app: app, context: "发布后 Feed")

        let publishedScreenshot = XCTAttachment(screenshot: app.screenshot())
        publishedScreenshot.name = "published-crazy-snake-candidate"
        publishedScreenshot.lifetime = .keepAlways
        add(publishedScreenshot)

    }

    @MainActor
    private func assertSnakeGameIsPlayable(in player: XCUIElement, app: XCUIApplication, context: String) {
        let start = firstButton(in: player, labels: ["START", "Start", "开始", "开始游戏"])
        XCTAssertTrue(start.waitForExistence(timeout: 10), "\(context)缺少开始游戏控件")
        let beforeStart = app.screenshot().pngRepresentation
        start.tap()
        Thread.sleep(forTimeInterval: 0.2)
        let afterStart = app.screenshot().pngRepresentation
        XCTAssertNotEqual(afterStart, beforeStart, "\(context)点击开始后画面没有变化")

        let pause = firstButton(in: player, labels: ["PAUSE", "Pause", "暂停"])
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "\(context)缺少暂停控件")
        pause.tap()
        let resume = firstButton(in: player, labels: ["RESUME", "Resume", "继续", "恢复"])
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "\(context)暂停后没有进入可恢复状态")
        resume.tap()

        let down = firstButton(in: player, labels: ["Down", "DOWN", "向下", "下"])
        XCTAssertTrue(down.waitForExistence(timeout: 5), "\(context)缺少向下方向控件")
        down.tap()
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertNotEqual(app.screenshot().pngRepresentation, afterStart, "\(context)点击方向键后画面没有继续变化")
    }

    @MainActor
    private func firstButton(in player: XCUIElement, labels: [String]) -> XCUIElement {
        player.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }
}
