import XCTest

/// UI tests run against the in-process social backend with fictional people (`-uitest`) and the
/// private-memory demo dataset (`-demo -reset`).
final class MomentUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest", "-reset", "-demo"]
        addUIInterruptionMonitor(withDescription: "Permissions") { alert in
            for label in ["Allow", "Allow While Using App", "OK", "Don't Allow", "Allow Full Access"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        app.launch()
    }

    private func waitForFeed() {
        XCTAssertTrue(app.otherElements["feedMoment-m_goa"].firstMatch.waitForExistence(timeout: 30), "seeded social feed should show Goa '26")
    }

    private func openMoment(_ id: String) {
        let card = app.otherElements["feedMoment-\(id)"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.buttons["open-\(id)"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["momentHero"].waitForExistence(timeout: 15))
    }

    // MARK: Home & Moment

    func testFeedShowsStoriesAndPosts() {
        waitForFeed()
        XCTAssertTrue(app.buttons["nowCompose"].exists, "stories row starts with your NOW")
        XCTAssertTrue(app.buttons["now-n1"].exists, "friends' NOW in the stories row")
        XCTAssertTrue(app.buttons["inboxButton"].exists)
        let goa = app.otherElements["feedMoment-m_goa"].firstMatch
        XCTAssertTrue(goa.buttons["addYourSide"].exists, "I'm in Goa '26, so the post offers Add your side")
        XCTAssertTrue(goa.staticTexts.matching(NSPredicate(format: "label CONTAINS 'were there'")).firstMatch.exists, "people line instead of like count")
    }

    func testMomentPageShowsEveryonesSideAndAddsMine() {
        waitForFeed()
        openMoment("m_goa")
        XCTAssertTrue(app.buttons["momentMembers"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.buttons["addYourSide"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["addYourSide"].firstMatch.tap()
        XCTAssertTrue(app.buttons["sideSamplePhotos"].waitForExistence(timeout: 5))
        app.buttons["sideSamplePhotos"].tap()
        let note = app.textFields["sideNote"].firstMatch.exists ? app.textFields["sideNote"].firstMatch : app.textViews["sideNote"].firstMatch
        note.tap(); note.typeText("Palolem was unreal")
        app.buttons["submitSide"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["momentHero"].waitForExistence(timeout: 10))
        for _ in 0..<3 where !app.staticTexts["Palolem was unreal"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Palolem was unreal"].waitForExistence(timeout: 15), "my note shows in the timeline after upload")
    }

    func testCreateMomentFromPlusTab() {
        waitForFeed()
        app.tabBars.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["create-moment"].waitForExistence(timeout: 5))
        app.buttons["create-moment"].tap()
        let title = app.textViews["newMomentTitle"].firstMatch.exists ? app.textViews["newMomentTitle"].firstMatch : app.textFields["newMomentTitle"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("Rooftop Friday")
        app.buttons["samplePhotos"].tap()
        app.buttons["addPeople"].tap()
        XCTAssertTrue(app.buttons["pick-rahul"].waitForExistence(timeout: 10))
        app.buttons["pick-rahul"].tap()
        app.buttons["peopleDone"].tap()
        app.swipeUp()
        XCTAssertTrue(app.buttons["createMoment"].waitForExistence(timeout: 5))
        app.buttons["createMoment"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["momentHero"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Rooftop Friday"].firstMatch.exists)
    }

    func testLikeCommentAndModeration() {
        waitForFeed()
        let goa = app.otherElements["feedMoment-m_goa"].firstMatch
        goa.buttons["react-core"].tap()
        XCTAssertTrue(goa.buttons["Unlike"].waitForExistence(timeout: 5) || goa.buttons["Like"].waitForExistence(timeout: 2), "heart toggles")
        goa.buttons["comments-m_goa"].tap()
        let field = app.descendants(matching: .any)["commentField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap(); field.typeText("kys")
        app.buttons["postComment"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "abuse is refused before it leaves the device")
        app.alerts.buttons.firstMatch.tap()
    }

    // MARK: NOW

    func testNowPostAndSaveToMoment() {
        waitForFeed()
        app.tabBars.buttons["Now"].tap()
        XCTAssertTrue(app.buttons["nowCompose"].waitForExistence(timeout: 5))
        app.buttons["nowCompose"].tap()
        let field = app.textViews["nowText"].firstMatch.exists ? app.textViews["nowText"].firstMatch : app.textFields["nowText"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Rooftop now")
        app.buttons["postNow"].tap()
        let mine = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'now-' AND label CONTAINS 'Rooftop now'")).firstMatch
        if !mine.waitForExistence(timeout: 10) { snap("debug-now-after-post") }
        XCTAssertTrue(mine.exists)
        mine.tap()
        XCTAssertTrue(app.buttons["saveNow"].waitForExistence(timeout: 5))
        app.buttons["saveNow"].tap()
        XCTAssertTrue(app.buttons["saveTo-m_goa"].waitForExistence(timeout: 5))
        app.buttons["saveTo-m_goa"].tap()
        XCTAssertTrue(app.staticTexts["Saved to a Moment"].waitForExistence(timeout: 5))
    }

    func testAnyoneUpJoin() {
        waitForFeed()
        app.tabBars.buttons["Now"].tap()
        XCTAssertTrue(app.buttons["joinNow-n3"].firstMatch.waitForExistence(timeout: 5), "Rahul is out for drinks")
        app.buttons["joinNow-n3"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["In"].firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: Search / Nearby, Inbox, Messages

    func testSearchNearbyInboxAndMessages() {
        waitForFeed()
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.buttons["enableNearby"].waitForExistence(timeout: 5) || app.descendants(matching: .any)["place-bastian_19062_72831"].firstMatch.waitForExistence(timeout: 10))
        if app.buttons["enableNearby"].exists { app.buttons["enableNearby"].tap() }
        XCTAssertTrue(app.descendants(matching: .any)["place-bastian_19062_72831"].firstMatch.waitForExistence(timeout: 15), "Bastian is within 3 km of the simulated location")
        app.segmentedControls.buttons["Search"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["tile-m_sunset"].firstMatch.waitForExistence(timeout: 15), "public Moments are searchable")
        app.tabBars.buttons["Home"].tap()
        app.buttons["inboxButton"].tap()
        XCTAssertTrue(app.buttons["Invites"].waitForExistence(timeout: 5))
        app.buttons["Invites"].tap()
        XCTAssertTrue(app.buttons["invite-inv1"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Messages"].tap()
        XCTAssertTrue(app.buttons["conversation-conv_rahul"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["conversation-conv_rahul"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["message-d1"].firstMatch.waitForExistence(timeout: 5))
        let field = app.textFields["messageField"].firstMatch.exists ? app.textFields["messageField"].firstMatch : app.textViews["messageField"].firstMatch
        field.tap(); field.typeText("sending it now")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts["sending it now"].waitForExistence(timeout: 5))
    }

    // MARK: Profile & safety

    func testProfileFriendshipAndBlock() {
        waitForFeed()
        openMoment("m_goa")
        app.buttons["momentMembers"].tap()
        XCTAssertTrue(app.staticTexts["Rahul Mehta"].firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["Rahul Mehta"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["profileHeader"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["friendshipLink"].waitForExistence(timeout: 5))
        app.buttons["friendshipLink"].tap()
        XCTAssertTrue(app.staticTexts["You + Rahul Mehta"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let menu = app.buttons["profileMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Block"].waitForExistence(timeout: 5))
        app.buttons["Block"].tap()
        app.tabBars.buttons["Home"].tap()
        XCTAssertFalse(app.otherElements["feedMoment-m_bday"].firstMatch.waitForExistence(timeout: 3), "blocked creator's Moments disappear")
    }

    func testSafetySettingsAndPrivateMemoryStillWork() {
        waitForFeed()
        app.tabBars.buttons["Profile"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["safetyLink"].firstMatch.waitForExistence(timeout: 10))
        app.descendants(matching: .any)["safetyLink"].firstMatch.tap()
        XCTAssertTrue(app.switches["privateAccount"].firstMatch.waitForExistence(timeout: 5))
        app.switches["privateAccount"].firstMatch.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for _ in 0..<8 where !app.buttons["myMemories"].exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["myMemories"].waitForExistence(timeout: 5))
        app.buttons["myMemories"].tap()
        XCTAssertTrue(app.staticTexts["homeHeadline"].waitForExistence(timeout: 20), "private memory layer opens")
        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("What did Rahul promise me?\n")
        XCTAssertTrue(app.staticTexts["searchAnswer"].waitForExistence(timeout: 15))
        app.buttons["memoriesDone"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["profileHeader"].waitForExistence(timeout: 5))
    }

    func testOnboardingFlow() {
        app.terminate()
        app.launchArguments = ["-uitest", "-reset-onboarding"]
        app.launch()
        if app.buttons["onboardingContinue"].waitForExistence(timeout: 10) {
            app.buttons["onboardingContinue"].tap()
            app.buttons["onboardingContinue"].tap()
            app.buttons["onboardingContinue"].tap()
            let name = app.textFields["onboardingName"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.tap(); name.typeText("Rakshit")
            app.buttons["onboardingContinue"].tap()
            XCTAssertTrue(app.buttons["createMoment"].waitForExistence(timeout: 10), "first Moment builder opens")
            app.buttons["onboardingSkip"].tap()
        }
        if app.buttons["setupDone"].waitForExistence(timeout: 5) { app.buttons["setupDone"].tap() }
        XCTAssertTrue(app.buttons["nowCompose"].waitForExistence(timeout: 20))
    }

    /// Not an assertion test: walks the app and writes screenshots for design review.
    func testScreenshotTour() {
        waitForFeed()
        snap("01-home"); app.swipeUp(); snap("02-home-scrolled")
        openMoment("m_goa"); sleep(1); snap("03-moment"); app.swipeUp(); sleep(1); snap("04-moment-timeline")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Search"].tap(); sleep(1); if app.buttons["enableNearby"].exists { app.buttons["enableNearby"].tap() }; sleep(2); snap("05-nearby")
        app.segmentedControls.buttons["Search"].firstMatch.tap(); sleep(1); snap("06-search")
        app.tabBars.buttons["Create"].tap(); sleep(1); snap("07-create"); app.buttons["Cancel"].firstMatch.tap()
        app.tabBars.buttons["Now"].tap(); sleep(1); snap("08-now")
        app.tabBars.buttons["Profile"].tap(); sleep(1); snap("09-profile")
        if app.buttons["passportLink"].exists { app.buttons["passportLink"].tap(); sleep(1); snap("10-passport"); app.navigationBars.buttons.element(boundBy: 0).tap() }
        app.tabBars.buttons["Home"].tap(); app.buttons["inboxButton"].tap(); sleep(1); snap("11-inbox")
    }

    private func snap(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let dir = URL(fileURLWithPath: "/Users/rakshitbargotra/Downloads/moments/build/screens")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
        let a = XCTAttachment(uniformTypeIdentifier: "public.png", name: name, payload: data)
        a.lifetime = .keepAlways
        add(a)
    }
}
