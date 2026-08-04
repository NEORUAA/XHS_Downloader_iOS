import XCTest

final class XHS_Downloader_iOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsTaskCenter() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["task-center-list"].waitForExistence(timeout: 8))
        let primaryButton = app.buttons["primary-paste-button"]
        XCTAssertTrue(primaryButton.waitForExistence(timeout: 3))
        let moreButton = app.buttons["more-actions-button"]
        XCTAssertTrue(moreButton.exists)

        let window = app.windows.firstMatch
        XCTAssertGreaterThan(primaryButton.frame.midY, window.frame.height * 0.72)
        XCTAssertEqual(primaryButton.frame.height, moreButton.frame.height, accuracy: 1)
        XCTAssertEqual(moreButton.frame.width, moreButton.frame.height, accuracy: 1)
    }
}
