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
    /// Opens a creator's profile from the feed by id, not by where they happen to rank. The feed is
    /// ranked, so anything that assumed a fixed order was testing the ranker by accident.
    ///
    /// A SwiftUI NavigationLink inside a LazyVStack reports `exists` as soon as it is realised but
    /// `isHittable` only once it is actually on screen, and XCUITest will not scroll a SwiftUI
    /// ScrollView by itself — so this scrolls until the link is on screen, then taps its centre.
    @discardableResult
    private func openCreator(_ creatorID: String) -> Bool {
        let link = app.descendants(matching: .any)["creatorLink-\(creatorID)"].firstMatch
        guard link.waitForExistence(timeout: 20) else { return false }
        for _ in 0..<25 {
            if link.isHittable {
                link.tap()
                if app.descendants(matching: .any)["profileHeader"].waitForExistence(timeout: 15) { return true }
                // The tap can land while the row is still settling; one retry is enough.
                if link.exists && link.isHittable { link.tap() }
                return app.descendants(matching: .any)["profileHeader"].waitForExistence(timeout: 15)
            }
            app.swipeUp()
        }
        return false
    }

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

    // MARK: Paid calls

    /// A confirmed call is the one thing on Home with a deadline, so it sits above the feed.
    func testAConfirmedCallCanBeJoinedFromHome() {
        waitForFeed()
        let banner = app.descendants(matching: .any)["joinCallBanner"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "a call whose window is open is offered on Home")
        snap("10-join-banner")
        banner.tap()
        XCTAssertTrue(app.descendants(matching: .any)["callLobby"].waitForExistence(timeout: 10), "the banner opens the call")
        XCTAssertTrue(app.buttons["joinCall"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["joinCall"].isEnabled, "the window is open, so Join is live")
        XCTAssertTrue(app.staticTexts["The clock starts when you're both connected"].exists, "the lobby states the rule the money turns on")
        snap("11-call-lobby")
    }

    /// Buying a call means picking from the creator's hours — not typing any time you like.
    func testBookingACallOffersOnlyTheCreatorsHours() {
        waitForFeed()
        app.tabBars.buttons["Profile"].tap()
        let about = app.buttons["About"].firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 10))
        // Straight to a creator who sells time.
        app.tabBars.buttons["Home"].tap()
        guard openCreator("u_sarah") else { return XCTFail("couldn't reach a creator who sells calls") }
        let shop = app.buttons["shopLink"].firstMatch
        for _ in 0..<8 where !(shop.exists && shop.isHittable) { app.swipeUp() }
        XCTAssertTrue(shop.exists, "a creator selling time has a shop")
        shop.tap()
        let voice = app.descendants(matching: .any)["offer-offer_voice_sarah"].firstMatch
        for _ in 0..<8 where !voice.exists { app.swipeUp() }
        XCTAssertTrue(voice.waitForExistence(timeout: 10), "the voice call is on the menu")
        voice.tap()
        // Slots, not a free-text date picker.
        let slot = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'slot-'")).firstMatch
        XCTAssertTrue(slot.waitForExistence(timeout: 10), "the buyer picks from the creator's hours")
        snap("12-slot-picker")
        let request = app.buttons["requestBooking"].firstMatch
        XCTAssertFalse(request.isEnabled, "nothing can be requested until a time is chosen")
        slot.tap()
        XCTAssertTrue(request.isEnabled, "picking a slot arms the request")
    }

    /// A creator's hours are the only place they say when they're free.
    func testACreatorSetsTheHoursCallsCanLandIn() {
        waitForFeed()
        app.tabBars.buttons["Profile"].tap()
        let studio = app.descendants(matching: .any)["Open Creator mode"].firstMatch
        let earn = app.descendants(matching: .any)["Start earning"].firstMatch
        if studio.waitForExistence(timeout: 8) { studio.tap() } else if earn.exists { earn.tap() } else { return XCTFail("no way into Creator mode") }
        let hours = app.descendants(matching: .any)["availabilityLink"].firstMatch
        for _ in 0..<10 where !hours.exists { app.swipeUp() }
        XCTAssertTrue(hours.waitForExistence(timeout: 10), "Creator mode is where hours are set")
        hours.tap()
        XCTAssertTrue(app.switches["acceptingBookings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["addWindow"].exists)
        snap("13-availability")
        app.buttons["addWindow"].tap()
        XCTAssertTrue(app.buttons["confirmWindow"].waitForExistence(timeout: 8))
        app.buttons["confirmWindow"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["availabilityPreview"].waitForExistence(timeout: 8), "the editor says what the rules add up to")
        app.buttons["saveAvailability"].firstMatch.tap()
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
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 10))
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
        // Under load the first tap sometimes lands while the picker is still animating in, so try twice.
        let reacted = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'reactions-'")).firstMatch
        fire.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if !reacted.waitForExistence(timeout: 8), fire.exists {
            fire.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(reacted.waitForExistence(timeout: 8), "reaction appears under the message")
        // Group chat opens from the groups strip.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let group = app.descendants(matching: .any)["groupChat-g_boys"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 8))
        group.tap()
        XCTAssertTrue(app.staticTexts["Goa again in Dec?"].waitForExistence(timeout: 10))
    }

    // MARK: Profile & safety

    func testProfileAndBlock() {
        waitForFeed()
        // Straight from a post to the creator's page.
        XCTAssertTrue(openCreator("u_sarah"), "a creator to open from the feed")
        XCTAssertTrue(app.buttons["subscribeBox"].waitForExistence(timeout: 8), "a creator page leads with the subscription")
        let menu = app.buttons["profileMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Block"].waitForExistence(timeout: 5))
        app.buttons["Block"].tap()
        app.tabBars.buttons["Home"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["post-s_set_sarah_kitchen"].firstMatch.waitForExistence(timeout: 3), "a blocked creator's posts leave the feed")
    }

    func testSafetySettingsAndPrivateMemoryStillWork() {
        waitForFeed()
        app.tabBars.buttons["Profile"].tap()
        let about = app.buttons["About"].firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 10))
        about.tap(); sleep(1)
        XCTAssertTrue(app.descendants(matching: .any)["safetyLink"].firstMatch.waitForExistence(timeout: 10))
        app.descendants(matching: .any)["safetyLink"].firstMatch.tap()
        XCTAssertTrue(app.switches["privateAccount"].firstMatch.waitForExistence(timeout: 5))
        app.switches["privateAccount"].firstMatch.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        if app.buttons["About"].firstMatch.waitForExistence(timeout: 5), !app.buttons["myMemories"].exists { app.buttons["About"].firstMatch.tap(); sleep(1) }
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
        XCTAssertTrue(openCreator("u_public"), "a creator to subscribe to")
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
        }
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
