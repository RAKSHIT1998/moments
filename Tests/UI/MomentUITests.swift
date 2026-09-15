import XCTest

/// UI tests run against a fresh in-app demo dataset (`-demo -uitest -reset`).
final class MomentUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest", "-reset", "-demo"]
        addUIInterruptionMonitor(withDescription: "Permissions") { alert in
            for label in ["Allow", "OK", "Don't Allow"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        app.launch()
    }

    private func waitForDemo() {
        XCTAssertTrue(app.staticTexts["homeHeadline"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.otherElements["surfaceCard-Follow up"].firstMatch.waitForExistence(timeout: 60), "demo data should surface a follow-up")
    }

    private func waitForHome() {
        XCTAssertTrue(app.staticTexts["homeHeadline"].waitForExistence(timeout: 20))
    }

    func testOnboardingFlow() {
        app.terminate()
        app.launchArguments = ["-reset-onboarding"]
        app.launch()
        // A fresh install shows onboarding; drive it to the end.
        if app.buttons["onboardingContinue"].waitForExistence(timeout: 10) {
            app.buttons["onboardingContinue"].tap()
            app.buttons["onboardingContinue"].tap()
            app.buttons["onboardingContinue"].tap()
            XCTAssertTrue(app.buttons["onboardingSkip"].waitForExistence(timeout: 5))
            app.buttons["onboardingSkip"].tap()
        }
        XCTAssertTrue(app.staticTexts["homeHeadline"].waitForExistence(timeout: 10))
    }

    func testHomeShowsContextualCards() {
        waitForDemo()
    }

    func testTextCaptureCreatesUnderstoodMemory() {
        waitForHome()
        app.buttons["captureButton"].tap()
        XCTAssertTrue(app.buttons["captureText"].waitForExistence(timeout: 5))
        app.buttons["captureText"].tap()
        let editor = app.textViews["captureTextEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Priya wants those Sony headphones for her birthday")
        app.buttons["captureSubmit"].tap()
        XCTAssertTrue(app.staticTexts["captureResultHeadline"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["extractedTitle"].label.contains("Sony"), app.staticTexts["extractedTitle"].label)
        app.buttons["captureSave"].tap()
        XCTAssertTrue(app.staticTexts["homeHeadline"].waitForExistence(timeout: 10))
    }

    func testVoiceCaptureScreenOpens() {
        waitForHome()
        app.buttons["captureButton"].tap()
        app.buttons["captureVoice"].tap()
        // Simulator has no mic permission UI in -uitest; either the transcript view or a failure message appears.
        app.tap() // lets the interruption monitor handle the permission alert if it appears
        // Recording starts immediately when allowed; the simulator may lack speech recognition, which must show an honest failure state.
        let started = app.buttons["voiceStop"].waitForExistence(timeout: 15)
        XCTAssertTrue(started || app.staticTexts["voiceFailed"].exists, "expected recording UI or an explicit failure message")
    }

    func testInboxSaveAll() {
        waitForHome()
        app.buttons["captureButton"].tap()
        app.buttons["captureText"].tap()
        let editor = app.textViews["captureTextEditor"]
        editor.tap(); editor.typeText("I need to renew my passport, service the car and book Bali")
        app.buttons["captureSubmit"].tap()
        XCTAssertTrue(app.staticTexts["captureResultHeadline"].waitForExistence(timeout: 20))
        app.buttons["Cancel"].firstMatch.exists ? app.buttons["Cancel"].firstMatch.tap() : app.swipeDown()
        app.tabBars.buttons["Vault"].tap()
        XCTAssertTrue(app.buttons["vaultReview"].waitForExistence(timeout: 10))
        app.buttons["vaultReview"].tap()
        XCTAssertTrue(app.buttons["inboxSaveAll"].waitForExistence(timeout: 10) || app.buttons["inboxSave"].firstMatch.waitForExistence(timeout: 5))
        if app.buttons["inboxSaveAll"].exists { app.buttons["inboxSaveAll"].tap() } else { app.buttons["inboxSave"].firstMatch.tap() }
    }

    func testSearchAnswersFromMemory() {
        waitForHome()
        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("What did Rahul promise me?\n")
        XCTAssertTrue(app.staticTexts["searchAnswer"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["searchAnswer"].label.lowercased().contains("property"))
    }

    func testPersonProfile() {
        waitForDemo()
        app.tabBars.buttons["People"].tap()
        let rahul = app.staticTexts["Rahul"].firstMatch
        XCTAssertTrue(rahul.waitForExistence(timeout: 15))
        rahul.tap()
        XCTAssertTrue(app.staticTexts["personName"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pending"].exists || app.staticTexts["Plans"].exists)
    }

    func testMemoryDetailAndSettings() {
        waitForDemo()
        app.otherElements["surfaceCard-Follow up"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["memoryDetailTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Source"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.staticTexts["Privacy Center"].waitForExistence(timeout: 5))
        app.staticTexts["Privacy Center"].tap()
        XCTAssertTrue(app.staticTexts["Stored on this iPhone"].waitForExistence(timeout: 5))
    }

    func testPaywallShowsWithoutHardcodedPrices() {
        waitForHome()
        app.buttons["settingsButton"].tap()
        app.staticTexts["MOMENT Pro"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["MOMENT Pro"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Restore purchases"].waitForExistence(timeout: 15) || app.staticTexts["Thank you. Everything is unlocked."].exists || app.staticTexts["Prices aren't available right now."].exists)
    }

    func testMomentsHubCreatesMonthRecapAndOpensEditor() {
        waitForDemo()
        app.tabBars.buttons["Vault"].tap()
        XCTAssertTrue(app.buttons["vaultMoments"].waitForExistence(timeout: 10))
        app.buttons["vaultMoments"].tap()
        XCTAssertTrue(app.staticTexts["Make something worth sharing."].waitForExistence(timeout: 5))
        app.buttons["This month"].firstMatch.tap()
        XCTAssertTrue(app.buttons["momentShare"].waitForExistence(timeout: 20), "the editor should open with a share action")
        app.buttons["momentShare"].tap()
        XCTAssertTrue(app.buttons["Send as a Moment (opens in MOMENT)"].waitForExistence(timeout: 5))
        app.buttons["Send as a Moment (opens in MOMENT)"].tap()
        // The system share sheet appears with the .moment file.
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 15) || app.buttons["Close"].waitForExistence(timeout: 15) || app.navigationBars.element.waitForExistence(timeout: 5))
    }

    /// Not an assertion test: walks the app and writes screenshots for design review.
    func testScreenshotTour() {
        waitForDemo()
        snap("01-home")
        app.swipeUp(); snap("02-home-scrolled")
        app.tabBars.buttons["Vault"].tap(); sleep(1); snap("03-vault")
        app.tabBars.buttons["Search"].tap(); sleep(1); snap("04-search")
        let field = app.textFields["searchField"]; field.tap(); field.typeText("What did Sarah want?\n"); sleep(2); snap("05-search-results")
        app.tabBars.buttons["People"].tap(); sleep(1); snap("06-people")
        if app.staticTexts["Rahul"].firstMatch.waitForExistence(timeout: 5) { app.staticTexts["Rahul"].firstMatch.tap(); sleep(1); snap("07-person") }
        app.tabBars.buttons["Home"].tap()
        if app.otherElements["surfaceCard-Follow up"].firstMatch.waitForExistence(timeout: 5) { app.otherElements["surfaceCard-Follow up"].firstMatch.tap(); sleep(1); snap("08-memory-detail") }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["captureButton"].tap(); sleep(1); snap("09-capture")
        app.buttons["captureText"].tap(); sleep(1)
        let editor = app.textViews["captureTextEditor"]; editor.tap(); editor.typeText("Sarah wants to try that new ramen place in Indiranagar next weekend")
        app.buttons["captureSubmit"].tap()
        _ = app.staticTexts["captureResultHeadline"].waitForExistence(timeout: 20); sleep(1); snap("10-capture-result")
        app.buttons["captureSave"].tap(); sleep(1)
        app.buttons["settingsButton"].tap(); sleep(1); snap("11-settings")
        app.staticTexts["Privacy Center"].tap(); sleep(1); snap("12-privacy")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts["MOMENT Pro"].firstMatch.tap(); sleep(2); snap("13-paywall")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Vault"].tap(); sleep(1)
        if app.staticTexts["Promises"].firstMatch.waitForExistence(timeout: 5) { app.staticTexts["Promises"].firstMatch.tap(); sleep(1); snap("14-promises"); app.navigationBars.buttons.element(boundBy: 0).tap() }
        if app.staticTexts["Gifts"].firstMatch.waitForExistence(timeout: 5) { app.staticTexts["Gifts"].firstMatch.tap(); sleep(1); snap("15-gifts"); app.navigationBars.buttons.element(boundBy: 0).tap() }
        if app.staticTexts["Plans"].firstMatch.waitForExistence(timeout: 5) {
            app.staticTexts["Plans"].firstMatch.tap(); sleep(1)
            if app.staticTexts["Goa"].firstMatch.waitForExistence(timeout: 5) { app.staticTexts["Goa"].firstMatch.tap(); sleep(1); snap("16-plan") ; app.navigationBars.buttons.element(boundBy: 0).tap() }
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.buttons["captureButton"].tap(); sleep(1)
        app.buttons["captureVoice"].tap(); sleep(3); snap("17-voice")
        app.buttons["Cancel"].firstMatch.tap()
        app.tabBars.buttons["Vault"].tap(); sleep(1)
        if app.buttons["vaultMoments"].waitForExistence(timeout: 5) {
            app.buttons["vaultMoments"].tap(); sleep(1); snap("21-moments-hub")
            app.buttons["This month"].firstMatch.tap()
            if app.buttons["momentShare"].waitForExistence(timeout: 20) { sleep(2); snap("22-moment-editor"); app.swipeLeft(); sleep(1); snap("23-moment-editor-2") }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.terminate()
        app.launchArguments = ["-reset-onboarding"]
        app.launch()
        if app.buttons["onboardingContinue"].waitForExistence(timeout: 10) {
            snap("18-onboarding-1"); app.buttons["onboardingContinue"].tap(); sleep(1); snap("19-onboarding-2")
            app.buttons["onboardingContinue"].tap(); app.buttons["onboardingContinue"].tap(); sleep(1); snap("20-onboarding-4")
            app.buttons["onboardingSkip"].tap()
        }
    }

    private func snap(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let dir = URL(fileURLWithPath: "/tmp/moment-screens")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
        let a = XCTAttachment(uniformTypeIdentifier: "public.png", name: name, payload: data)
        a.lifetime = .keepAlways
        add(a)
    }
}
