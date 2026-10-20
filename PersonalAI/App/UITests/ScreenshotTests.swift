import XCTest

/// Drives the real app on a Simulator with deterministic synthetic data, asserts that the key screens appear, and attaches a screenshot of each.
/// (No model is loaded here: MLX needs a physical GPU. These tests verify launch, navigation, copy, and that data flows into the UI.)
final class ScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"] + extra
        app.launch()
        return app
    }
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways
        add(a)
    }
    private func text(_ app: XCUIApplication, _ s: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts[s].firstMatch.waitForExistence(timeout: timeout), "expected on screen: \(s)", file: file, line: line)
    }

    func testOnboarding() {
        let app = launch(["--uitest-onboarding"])
        text(app, "An AI that lives on your phone.")
        shot("01-welcome")
        app.buttons["Continue"].tap()
        text(app, "Everything stays here.")
        shot("02-private")
        app.buttons["Continue"].tap()
        text(app, "Pick a model.")
        shot("03-pick-model")
        XCTAssertTrue(app.buttons["Download and start"].exists)
    }

    func testTabsShowSeededData() {
        let app = launch()
        text(app, "Chats")
        text(app, "Kitchen renovation")
        shot("10-chats")

        app.staticTexts["Kitchen renovation"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Back to chats"].waitForExistence(timeout: 10))
        shot("11-chat-history-no-model")
        app.buttons["Back to chats"].tap()

        app.buttons["Memory"].tap()
        text(app, "Memory")
        shot("20-memory-notes")
        let note = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'Helix Robotics'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20), "a note learned from the imported job-change message")
        note.tap()
        text(app, "Evidence")
        shot("21-memory-evidence")
        app.navigationBars.buttons.firstMatch.tap()
        app.segmentedControls.buttons["Search"].tap()
        let field = app.textFields.firstMatch
        field.tap(); field.typeText("which guesthouse is in Lisbon\n")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Casa do Largo")).firstMatch.waitForExistence(timeout: 30), "search finds the hotel message")
        shot("22-search-results")

        app.buttons["Library"].tap()
        text(app, "Library")
        shot("30-library")

        app.buttons["Models"].tap()
        text(app, "Models")
        text(app, "Qwen3 4B")
        shot("40-models")

        app.buttons["Privacy"].tap()
        text(app, "Your conversations never leave this iPhone.")
        shot("50-privacy")
    }
}
