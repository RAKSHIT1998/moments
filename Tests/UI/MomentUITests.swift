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

    /// Home opens on the creator Feed; the Moments stack is the second segment.
    private func waitForFeed() {
        let moments = app.buttons["Moments"].firstMatch
        if moments.waitForExistence(timeout: 20), !moments.isSelected { moments.tap(); sleep(1) }
        if !app.otherElements["feedMoment-m_goa"].firstMatch.waitForExistence(timeout: 10) { snap("debug-home-segments") }
        XCTAssertTrue(app.otherElements["feedMoment-m_goa"].firstMatch.waitForExistence(timeout: 30), "seeded social feed should show Goa '26")
    }

    private func goHomeFeed() {
        app.tabBars.buttons["Home"].tap()
        let feed = app.buttons["Feed"].firstMatch
        if feed.waitForExistence(timeout: 10), !feed.isSelected { feed.tap(); sleep(2) }
    }

    private func openMoment(_ id: String) {
        let card = app.otherElements["feedMoment-\(id)"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        let open = card.buttons["open-\(id)"].firstMatch
        for _ in 0..<6 where !open.isHittable { app.swipeUp() }
        if !open.isHittable { for _ in 0..<6 where !open.isHittable { app.swipeDown() } }
        open.tap()
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
        // The refusal is shown where it happened (or as an alert, when the composer is a sheet).
        let inline = app.descendants(matching: .any)["commentError"].firstMatch
        let refused = inline.waitForExistence(timeout: 8) || app.alerts.firstMatch.waitForExistence(timeout: 2)
        if !refused { snap("debug-moderation") }
        XCTAssertTrue(refused, "abuse is refused before it leaves the device")
        if app.alerts.firstMatch.exists { app.alerts.buttons.firstMatch.tap() }
    }

    // MARK: NOW

    func testNowPostAndSaveToMoment() {
        waitForFeed()
        app.buttons["nowLink"].tap()
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
        app.buttons["nowLink"].tap()
        if !app.buttons["joinNow-n3"].firstMatch.waitForExistence(timeout: 8) { snap("debug-now-link") }
        XCTAssertTrue(app.buttons["joinNow-n3"].firstMatch.waitForExistence(timeout: 5), "Rahul is out for drinks")
        app.buttons["joinNow-n3"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["In"].firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: Search / Nearby, Inbox, Messages

    func testSearchNearbyInboxAndMessages() {
        waitForFeed()
        // Nearby lives in the Home header now that Explore is gone.
        app.buttons["nearbyLink"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["place-bastian_19062_72831"].firstMatch.waitForExistence(timeout: 20), "Bastian is within 3 km of the simulated location")
        app.navigationBars.buttons.element(boundBy: 0).tap()
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
            XCTAssertTrue(app.buttons["createMoment"].waitForExistence(timeout: 10), "first Moment builder opens")
            app.buttons["onboardingSkip"].tap()
        }
        if app.buttons["setupDone"].waitForExistence(timeout: 5) { app.buttons["setupDone"].tap() }
        XCTAssertTrue(app.buttons["nowCompose"].waitForExistence(timeout: 20))
    }

    /// Not an assertion test: walks the app and writes screenshots for design review.
    func testCreatorPaywallSubscribeAndEarn() {
        waitForFeed()
        // Page through the stack until the locked paid Moment is on screen; unlock it.
        let unlock = app.descendants(matching: .any)["unlock-m_raw"].firstMatch
        for _ in 0..<30 where !(unlock.exists && unlock.isHittable) { app.swipeUp(); sleep(1) }
        XCTAssertTrue(unlock.exists && unlock.isHittable, "paid preview from a followed creator is in the feed")
        snap("12-locked")
        unlock.tap()
        let subscribe = app.buttons["subscribeButton"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 20))
        snap("13-subscribe")
        subscribe.tap()   // demo host: recorded without an App Store purchase
        // Success shows "You're in" for a beat, then the sheet dismisses itself over the unlocked Moment.
        let gone = NSPredicate(format: "exists == false")
        let dismissed = XCTNSPredicateExpectation(predicate: gone, object: subscribe)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 40), .completed, "sheet goes away after the purchase")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        sleep(2)
        XCTAssertFalse(unlock.exists && unlock.isHittable, "lock is gone once subscribed")
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
        openMoment("m_goa"); sleep(1); snap("03-moment"); app.swipeUp(); sleep(1); snap("04-moment-timeline")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["nearbyLink"].firstMatch.tap(); sleep(3); snap("05-nearby"); app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Create"].tap(); sleep(1); snap("07-create"); app.buttons["Cancel"].firstMatch.tap()
        goHomeFeed(); sleep(2); snap("08a-creator-feed")
        app.buttons["nowLink"].firstMatch.exists ? app.buttons["nowLink"].firstMatch.tap() : app.buttons["reelsLink"].firstMatch.tap(); sleep(1); snap("08-now"); app.navigationBars.buttons.element(boundBy: 0).tap()
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
