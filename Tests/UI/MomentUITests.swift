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

    /// Home is the creator feed.
    private func waitForFeed() {
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'post-'")).firstMatch.waitForExistence(timeout: 30), "the feed shows creators' posts")
    }


    // MARK: Home & Moment

    // MARK: The feed people pay in

    func testFeedShowsLockedAndFreePostsWithPrices() {
        waitForFeed()
        // A locked post says what opens it and what it costs — never a bare thumbnail.
        let locked = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'unlockPost-' OR identifier BEGINSWITH 'subscribePost-'")).firstMatch
        XCTAssertTrue(locked.waitForExistence(timeout: 20), "a paid post is in the feed with its price on the lock")
        XCTAssertTrue(locked.label.contains("₹"), "the price is on the button: \(locked.label)")
        XCTAssertTrue(app.buttons["inboxButton"].exists)
        XCTAssertTrue(app.buttons["reelsLink"].exists)
    }

    func testUnlockingAPaidSetOpensIt() {
        waitForFeed()
        let unlock = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'unlockPost-'")).firstMatch
        for _ in 0..<10 where !(unlock.exists && unlock.isHittable) { app.swipeUp(); sleep(1) }
        XCTAssertTrue(unlock.exists && unlock.isHittable, "a set to buy")
        unlock.tap()
        XCTAssertTrue(app.buttons["buySet"].waitForExistence(timeout: 10))
        app.buttons["buySet"].tap()
        XCTAssertTrue(app.buttons["See it"].waitForExistence(timeout: 15), "paying opens it")
        app.buttons["See it"].tap()
    }

    func testReelsPlayVideoPostsAndLockPaidOnes() {
        waitForFeed()
        app.buttons["reelsLink"].firstMatch.tap()
        let anyReel = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'reel-'")).firstMatch
        XCTAssertTrue(anyReel.waitForExistence(timeout: 20), "video posts play in reels")
        snap("20-reels")
        app.swipeUp(); sleep(2)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'reel-'")).firstMatch.exists)
    }

    func testCreateSheetIsAboutPosts() {
        waitForFeed()
        app.tabBars.buttons["Create"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["create-photo"].firstMatch.waitForExistence(timeout: 10), "a photo set is the first thing you can make")
        XCTAssertTrue(app.descendants(matching: .any)["create-video"].firstMatch.exists)
        snap("07-create")
        app.buttons["Cancel"].firstMatch.tap()
    }

    // MARK: Inbox, Messages

    func testInboxAndMessages() {
        waitForFeed()
        XCTAssertTrue(app.buttons["inboxButton"].waitForExistence(timeout: 10))
        app.buttons["inboxButton"].tap()
        if !app.buttons["Invites"].waitForExistence(timeout: 10) { snap("debug-inbox-tap") }
        XCTAssertTrue(app.buttons["Invites"].exists)
        app.buttons["Invites"].tap()
        XCTAssertTrue(app.buttons["invite-inv1"].firstMatch.waitForExistence(timeout: 5))
        app.tabBars.buttons["Chats"].tap()
        let chat = app.descendants(matching: .any)["chat-conv_rahul"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.tap()
        XCTAssertTrue(app.descendants(matching: .any)["message-d1"].firstMatch.waitForExistence(timeout: 10))
        let field = app.textFields["messageField"].firstMatch.exists ? app.textFields["messageField"].firstMatch : app.textViews["messageField"].firstMatch
        field.tap(); field.typeText("sending it now")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts["sending it now"].waitForExistence(timeout: 8))
        // Reply + react on a message.
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'message-' AND label == 'sending it now'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        sent.press(forDuration: 0.6)
        let fire = app.buttons["react-🔥"].firstMatch
        XCTAssertTrue(fire.waitForExistence(timeout: 5))
        // The picker floats over the thread; tap its centre rather than letting XCUITest scroll to it.
        fire.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["🔥"].firstMatch.waitForExistence(timeout: 8), "reaction appears under the message")
        // Group chat opens from the groups strip.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let group = app.descendants(matching: .any)["groupChat-g_boys"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 8))
        group.tap()
        XCTAssertTrue(app.staticTexts["Goa again in Dec?"].waitForExistence(timeout: 10))
    }

    // MARK: Profile & safety

    func testProfileFriendshipAndBlock() {
        waitForFeed()
        // Straight from a post to the creator's page.
        let sarah = app.buttons["Sarah Kim"].firstMatch
        for _ in 0..<10 where !(sarah.exists && sarah.isHittable) { app.swipeUp(); sleep(1) }
        XCTAssertTrue(sarah.exists && sarah.isHittable)
        sarah.tap()
        XCTAssertTrue(app.descendants(matching: .any)["profileHeader"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["subscribeBox"].waitForExistence(timeout: 8), "a creator page leads with the subscription")
        // Sarah and I share Moments, so the "you two" link is there.
        if app.buttons["friendshipLink"].waitForExistence(timeout: 5) {
            app.buttons["friendshipLink"].tap()
            XCTAssertTrue(app.staticTexts["You + Sarah Kim"].waitForExistence(timeout: 8))
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
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
        let people = app.buttons["People"].firstMatch
        XCTAssertTrue(people.waitForExistence(timeout: 10))
        people.tap(); sleep(1)
        XCTAssertTrue(app.descendants(matching: .any)["safetyLink"].firstMatch.waitForExistence(timeout: 10))
        app.descendants(matching: .any)["safetyLink"].firstMatch.tap()
        XCTAssertTrue(app.switches["privateAccount"].firstMatch.waitForExistence(timeout: 5))
        app.switches["privateAccount"].firstMatch.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        if app.buttons["People"].firstMatch.waitForExistence(timeout: 5), !app.buttons["myMemories"].exists { app.buttons["People"].firstMatch.tap(); sleep(1) }
        for _ in 0..<8 where !app.buttons["myMemories"].exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["myMemories"].waitForExistence(timeout: 5))
        app.buttons["myMemories"].tap()
        XCTAssertTrue(app.staticTexts["homeHeadline"].waitForExistence(timeout: 20), "private memory layer opens")
        let hubSearch = app.tabBars.allElementsBoundByIndex.map { $0.buttons["Search"] }.first { $0.isHittable }   // the private hub's own tab bar, not the covered main one
        XCTAssertNotNil(hubSearch)
        hubSearch?.tap()
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
            XCTAssertTrue(app.descendants(matching: .any)["onboardingMomentID"].firstMatch.waitForExistence(timeout: 10), "identity step shows the MOMENT ID")
            app.buttons["identityContinue"].tap()
            if app.buttons["onboardingSkip"].waitForExistence(timeout: 10) { app.buttons["onboardingSkip"].tap() }
        }
        if app.buttons["setupDone"].waitForExistence(timeout: 5) { app.buttons["setupDone"].tap() }
        XCTAssertTrue(app.buttons["reelsLink"].waitForExistence(timeout: 25), "you land on the feed")
    }

    /// Not an assertion test: walks the app and writes screenshots for design review.
    func testCreatorPaywallSubscribeAndEarn() {
        waitForFeed()
        snap("12-locked")
        // Subscribing happens on the creator's page.
        let creator = app.buttons["Sunset Society"].firstMatch
        for _ in 0..<12 where !(creator.exists && creator.isHittable) { app.swipeUp(); sleep(1) }
        XCTAssertTrue(creator.exists && creator.isHittable, "a creator to subscribe to")
        creator.tap()
        let box = app.buttons["subscribeBox"].firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 15), "their page leads with the subscription")
        box.tap()
        let subscribe = app.buttons["subscribeButton"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 20))
        snap("13-subscribe")
        subscribe.tap()   // demo host: recorded without an App Store purchase
        // Success shows "You're in" for a beat, then the sheet dismisses itself over the unlocked Moment.
        let gone = NSPredicate(format: "exists == false")
        let dismissed = XCTNSPredicateExpectation(predicate: gone, object: subscribe)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 40), .completed, "sheet goes away after the purchase")
        sleep(2)   // the sheet dismisses itself; tapping Done would race with it
        XCTAssertTrue(app.buttons["subscribeBox"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["subscribeBox"].firstMatch.isEnabled, "the button says subscribed and can't be pressed again")
        // Creator side: set up a plan and see the earnings screen.
        app.tabBars.buttons["Profile"].tap()
        let studio = app.descendants(matching: .any)["studioLink"].firstMatch
        XCTAssertTrue(studio.waitForExistence(timeout: 10))
        studio.tap()
        let toPlan = app.buttons["setUpPlan"].firstMatch.waitForExistence(timeout: 8) ? app.buttons["setUpPlan"].firstMatch : app.buttons["editPlanLink"].firstMatch
        XCTAssertTrue(toPlan.waitForExistence(timeout: 8)); toPlan.tap()
        let title = app.descendants(matching: .any)["planTitle"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap(); title.typeText("Behind the lens")
        let pitch = app.descendants(matching: .any)["planPitch"].firstMatch
        pitch.tap(); pitch.typeText("Every frame, same night.\n")
        // One subscription, the creator's own price.
        let priceField = app.descendants(matching: .any)["planPrice"].firstMatch
        XCTAssertTrue(priceField.waitForExistence(timeout: 8))
        priceField.tap(); priceField.typeText("750")
        snap("14-earn-setup")
        app.swipeUp(); app.swipeUp()
        XCTAssertTrue(app.buttons["savePlan"].waitForExistence(timeout: 8))
        app.buttons["savePlan"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["earningsEstimate"].firstMatch.waitForExistence(timeout: 10))
        snap("15-earn")
    }

    func testScreenshotTour() {
        waitForFeed()
        snap("01-home"); app.swipeUp(); snap("02-home-scrolled")
        app.buttons["reelsLink"].firstMatch.tap(); sleep(3); snap("03-reels")
        if app.buttons["Close reels"].firstMatch.exists { app.buttons["Close reels"].firstMatch.tap() } else { app.swipeDown() }
        sleep(1)
        app.tabBars.buttons["Create"].tap(); sleep(1); snap("07-create"); app.buttons["Cancel"].firstMatch.tap()
        app.tabBars.buttons["Chats"].tap(); sleep(2); snap("08b-chats")
        app.tabBars.buttons["Profile"].tap(); sleep(2); snap("09-profile")
        if app.buttons["studioLink"].firstMatch.waitForExistence(timeout: 5) {
            app.buttons["studioLink"].firstMatch.tap(); sleep(2); snap("09b-creator-mode")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
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
