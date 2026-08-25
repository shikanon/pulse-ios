import XCTest

final class ResourceLibraryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOriginalCreationSelectsOfficialBGMFromPublicLibrary() throws {
        let app = XCUIApplication()
        app.launch()

        let createTab = app.buttons["Create an original app from one sentence"]
        XCTAssertTrue(createTab.waitForExistence(timeout: 10))
        createTab.tap()

        let libraryButton = app.buttons["creation.resource-library"]
        XCTAssertTrue(libraryButton.waitForExistence(timeout: 5), "一句话创作没有资源库入口")
        libraryButton.tap()

        let officialBGM = app.buttons["Select Arcade Rush BGM"]
        XCTAssertTrue(officialBGM.waitForExistence(timeout: 10), "公共资源库没有加载官方 BGM")
        officialBGM.tap()
        app.buttons["Done"].tap()

        XCTAssertTrue(app.staticTexts["Arcade Rush BGM"].waitForExistence(timeout: 5), "选中的公共 BGM 没有回填创作输入")
        XCTAssertTrue(app.staticTexts["Official public resource"].exists, "公共资源来源没有清晰展示")
    }
}
