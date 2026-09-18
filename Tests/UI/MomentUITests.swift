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
            for label in ["Allow", "OK", "Don't Allow", "Allow Full Access"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        app.launch()
    }

    private func waitForFeed() {
        XCTAssertTrue(app.otherElements["feedMoment-m_goa"].firstMatch.waitForExistence(timeout: 30), "seeded social feed should show Goa '26")
    }

    // MARK: Social

    func testFeedRanksMomentsIWasPartOfFirst() {
        waitForFeed()
        XCTAssertTrue(app.buttons["nowCompose"].exists)
        XCTAssertTrue(app.buttons["now-n1"].exists, "NOW strip shows friends' posts")
        XCTAssertTrue(app.otherElements["onThisDay"].firstMatch.exists, "Goa '25 was one year ago today")
        let first = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'feedMoment-'")).firstMatch
        XCTAssertTrue(["feedMoment-m_goa", "feedMoment-m_bday"].contains(first.identifier), first.identifier)
    }

    func testMomentPageShowsEveryonesSideAndAddsMine() {
        waitForFeed()
        app.otherElements["feedMoment-m_goa"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["momentHero"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["You were there too."].exists)
        XCTAssertTrue(app.otherElements["contribution-c_m_goa_1"].firstMatch.waitForExistence(timeout: 5), "Rahul's side is in the timeline")
        app.swipeUp()
        XCTAssertTrue(app.buttons["addYourSide"].waitForExistence(timeout: 5))
        app.buttons["addYourSide"].tap()
        XCTAssertTrue(app.buttons["sideSamplePhotos"].waitForExistence(timeout: 5))
        app.buttons["sideSamplePhotos"].tap()
        let note = app.textFields["sideNote"].firstMatch.exists ? app.textFields["sideNote"].firstMatch : app.textViews["sideNote"].firstMatch
        note.tap(); note.typeText("Palolem was unreal")
        app.buttons["submitSide"].tap()
        XCTAssertTrue(app.otherElements["momentHero"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Palolem was unreal"].waitForExistence(timeout: 15), "my note shows in the Moment after upload")
    }

    func testCreateMomentAndInvite() {
        waitForFeed()
        app.tabBars.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["create-moment"].waitForExistence(timeout: 5)); app.buttons["create-moment"].tap()
        let title = app.textViews["newMomentTitle"].firstMatch.exists ? app.textViews["newMomentTitle"].firstMatch : app.textFields["newMomentTitle"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("Rooftop Friday")
        app.buttons["samplePhotos"].tap()
        app.buttons["addPeople"].tap()
        XCTAssertTrue(app.buttons["pick-rahul"].waitForExistence(timeout: 10))
        app.buttons["pick-rahul"].tap()
        app.buttons["peopleDone"].tap()
        app.buttons["vis-group"].tap()
        app.swipeUp()
        app.buttons["createMoment"].tap()
        XCTAssertTrue(app.otherElements["momentHero"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Rooftop Friday"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Rahul Mehta + you"].waitForExistence(timeout: 10), "invited person is a member")
    }

    func testReactCommentAndModeration() {
        waitForFeed()
        app.otherElements["feedMoment-m_goa"].firstMatch.tap()
        app.swipeUp(); app.swipeUp()
        if app.buttons["Details"].firstMatch.waitForExistence(timeout: 5) { app.buttons["Details"].firstMatch.tap() }
        XCTAssertTrue(app.buttons["react-core"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["react-core"].firstMatch.tap()
        XCTAssertTrue(app.buttons["react-core"].firstMatch.label.contains("selected"))
        app.swipeUp(); app.swipeUp(); app.swipeUp()
        let field = app.textFields["commentField"].firstMatch.exists ? app.textFields["commentField"].firstMatch : app.textViews["commentField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("kys")
        app.buttons["postComment"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "abuse is refused before it leaves the device")
        app.alerts.buttons.firstMatch.tap()
    }

    func testNowPostAndSaveToMoment() {
        waitForFeed()
        app.tabBars.buttons["Now"].tap()
        XCTAssertTrue(app.buttons["nowCompose"].waitForExistence(timeout: 5))
        app.buttons["nowCompose"].tap()
        let field = app.textViews["nowText"].firstMatch.exists ? app.textViews["nowText"].firstMatch : app.textFields["nowText"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Rooftop now")
        app.buttons["postNow"].tap()
        let mine = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'now-'")).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 10))
        mine.tap()
        XCTAssertTrue(app.buttons["saveNow"].waitForExistence(timeout: 5))
        app.buttons["saveNow"].tap()
        XCTAssertTrue(app.buttons["saveTo-m_goa"].waitForExistence(timeout: 5))
        app.buttons["saveTo-m_goa"].tap()
        XCTAssertTrue(app.staticTexts["Saved to a Moment"].waitForExistence(timeout: 5))
    }

    func testDiscoverInboxAndMessages() {
        waitForFeed()
        app.tabBars.buttons["Discover"].tap()
        XCTAssertTrue(app.otherElements["tile-m_sunset"].firstMatch.waitForExistence(timeout: 10), "public Moments are discoverable")
        app.buttons["inboxButton"].tap()
        XCTAssertTrue(app.otherElements["activity-a1"].firstMatch.waitForExistence(timeout: 10) || app.buttons["activity-a1"].firstMatch.waitForExistence(timeout: 2))
        app.buttons["Invites"].tap()
        XCTAssertTrue(app.buttons["invite-inv1"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Messages"].tap()
        XCTAssertTrue(app.buttons["conversation-conv_rahul"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["conversation-conv_rahul"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["message-d1"].firstMatch.waitForExistence(timeout: 5))
        let field = app.textFields["messageField"].firstMatch.exists ? app.textFields["messageField"].firstMatch : app.textViews["messageField"].firstMatch
        field.tap(); field.typeText("sending it now")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts["sending it now"].waitForExistence(timeout: 5))
    }

    func testProfileFriendshipAndBlock() {
        waitForFeed()
        app.otherElements["feedMoment-m_goa"].firstMatch.tap()
        XCTAssertTrue(app.buttons["momentMembers"].waitForExistence(timeout: 10))
        app.buttons["momentMembers"].tap()
        XCTAssertTrue(app.staticTexts["Rahul Mehta"].firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["Rahul Mehta"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["profileHeader"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["friendshipLink"].waitForExistence(timeout: 5))
        app.buttons["friendshipLink"].tap()
        XCTAssertTrue(app.staticTexts["You + Rahul Mehta"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["profileMenu"].tap()
        app.buttons["Block"].tap()
        // Back on the Moment page; Rahul's Moment is gone from the feed.
        app.tabBars.buttons["Home"].tap()
        XCTAssertFalse(app.otherElements["feedMoment-m_bday"].firstMatch.waitForExistence(timeout: 3), "blocked creator's Moments disappear")
    }

    func testSafetySettingsAndPrivateMemoryStillWork() {
        waitForFeed()
        app.tabBars.buttons["Profile"].tap()
        XCTAssertTrue(app.buttons["safetyLink"].waitForExistence(timeout: 10))
        app.buttons["safetyLink"].tap()
        XCTAssertTrue(app.switches["privateAccount"].firstMatch.waitForExistence(timeout: 5))
        app.switches["privateAccount"].firstMatch.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["myMemories"].tap()
        XCTAssertTrue(app.staticTexts["homeHeadline"].waitForExistence(timeout: 20), "private memory layer opens")
        XCTAssertTrue(app.otherElements["surfaceCard-Follow up"].firstMatch.waitForExistence(timeout: 60), "demo data still surfaces")
        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("What did Rahul promise me?\n")
        XCTAssertTrue(app.staticTexts["searchAnswer"].waitForExistence(timeout: 15))
        app.buttons["memoriesDone"].tap()
        XCTAssertTrue(app.otherElements["profileHeader"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.buttons["nowCompose"].waitForExistence(timeout: 20))
    }

    /// Not an assertion test: walks the app and writes screenshots for design review.
    func testScreenshotTour() {
        waitForFeed()
        snap("01-home"); app.swipeUp(); snap("02-home-scrolled")
        app.otherElements["feedMoment-m_goa"].firstMatch.tap(); _ = app.otherElements["momentHero"].waitForExistence(timeout: 10); sleep(1); snap("03-moment")
        app.swipeUp(); sleep(1); snap("04-moment-timeline")
        app.buttons["addYourSide"].tap(); sleep(1); snap("05-add-side")
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["nowCompose"].tap(); sleep(1); snap("06-now-compose"); app.buttons["Cancel"].tap()
        if app.buttons["now-n1"].exists { app.buttons["now-n1"].tap(); sleep(1); snap("07-now-viewer"); app.buttons["nowClose"].tap() }
        app.tabBars.buttons["Discover"].tap(); sleep(1); snap("08-discover")
        app.tabBars.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["create-moment"].waitForExistence(timeout: 5)); app.buttons["create-moment"].tap(); sleep(1); snap("09-new-moment")
        app.buttons["inboxButton"].tap(); sleep(1); snap("10-inbox")
        app.buttons["Messages"].tap(); sleep(1); snap("11-messages")
        if app.buttons["conversation-conv_rahul"].firstMatch.exists { app.buttons["conversation-conv_rahul"].firstMatch.tap(); sleep(1); snap("12-conversation"); app.navigationBars.buttons.element(boundBy: 0).tap() }
        app.tabBars.buttons["Profile"].tap(); sleep(1); snap("13-profile")
        app.buttons["safetyLink"].tap(); sleep(1); snap("14-safety"); app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["myMemories"].tap(); _ = app.staticTexts["homeHeadline"].waitForExistence(timeout: 20); sleep(1); snap("15-private-home")
        app.buttons["memoriesDone"].tap()
        app.terminate()
        app.launchArguments = ["-uitest", "-reset-onboarding"]
        app.launch()
        if app.buttons["onboardingContinue"].waitForExistence(timeout: 10) {
            snap("16-onboarding-1"); app.buttons["onboardingContinue"].tap(); sleep(1); snap("17-onboarding-2")
            app.buttons["onboardingContinue"].tap(); sleep(1); snap("18-onboarding-3"); app.buttons["onboardingContinue"].tap(); sleep(1); snap("19-onboarding-profile")
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
