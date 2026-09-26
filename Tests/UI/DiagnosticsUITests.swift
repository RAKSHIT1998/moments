import XCTest

/// Not assertions: dumps the element tree of the main screens when a query stops matching.
/// Cheap to keep, and the first thing worth reading when a UI test fails for no obvious reason.
final class DiagnosticsUITests: XCTestCase {
    func testDumpTrees() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-demo", "-reset"]
        app.launch()
        let post = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'post-'")).firstMatch
        XCTAssertTrue(post.waitForExistence(timeout: 30), "the creator feed should have posts")
        print("── HOME ──\n" + app.debugDescription)
        app.tabBars.buttons["Profile"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["profileHeader"].waitForExistence(timeout: 15))
        print("── PROFILE ──\n" + app.debugDescription)
        app.tabBars.buttons["Chats"].tap()
        sleep(2)
        print("── CHATS ──\n" + app.debugDescription)
    }

    /// Tapping a creator's name in the feed should open their page. Dumps what's on screen before and
    /// after, so a tap that lands but doesn't navigate is visible rather than guessed at.
    func testTapCreatorLinkFromFeed() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-demo", "-reset"]
        app.launch()
        let post = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'post-'")).firstMatch
        XCTAssertTrue(post.waitForExistence(timeout: 30))
        let link = app.descendants(matching: .any)["creatorLink-u_sarah"].firstMatch
        var swipes = 0
        while !link.isHittable && swipes < 25 { app.swipeUp(); swipes += 1 }
        print("── swipes: \(swipes), exists: \(link.exists), hittable: \(link.isHittable), frame: \(link.frame) ──")
        print("── BEFORE TAP ──\n" + app.debugDescription)
        link.tap()
        sleep(3)
        print("── AFTER TAP ──\n" + app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        shot.name = "after-creator-tap"
        add(shot)
    }

    /// Screens for eyeballing a redesign. Not assertions — pictures.
    ///
    /// Off by default. It walks most of the app, types into a search field and writes a dozen PNGs,
    /// which takes minutes and times out on a loaded machine — and a tool that turns the suite red
    /// without anything being wrong is worse than no tool. Run it when you want to look at something:
    ///
    ///     CAPTURE=1 xcodebuild test -only-testing:MomentUITests/DiagnosticsUITests/testCaptureRedesign …
    func testCaptureRedesign() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CAPTURE"] != nil,
                          "set CAPTURE=1 to write screenshots")
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-demo", "-reset"]
        app.launch()
        let post = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'post-'")).firstMatch
        XCTAssertTrue(post.waitForExistence(timeout: 30))

        func snap(_ name: String) {
            let a = XCTAttachment(screenshot: app.screenshot()); a.lifetime = .keepAlways; a.name = name; add(a)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/redesign-\(name).png"))
        }
        sleep(2); snap("home")
        let discover = app.descendants(matching: .any)["discoverLink"].firstMatch
        if discover.waitForExistence(timeout: 8) {
            discover.tap(); sleep(3); snap("discover")
            let field = app.searchFields.firstMatch
            if field.waitForExistence(timeout: 5) {
                field.tap(); field.typeText("sar"); sleep(2); snap("discover-search")
            }
            app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(1)
        }
        app.swipeUp(); sleep(1); snap("home-scrolled")
        app.tabBars.buttons["Profile"].tap()
        sleep(3); snap("profile")
        let studio = app.descendants(matching: .any)["Open Creator mode"].firstMatch
        let earn = app.descendants(matching: .any)["Start earning"].firstMatch
        if studio.waitForExistence(timeout: 5) { studio.tap() } else if earn.exists { earn.tap() }
        sleep(3); snap("creator-mode")
        app.tabBars.buttons["Profile"].tap(); sleep(2)
        let about = app.buttons["About"].firstMatch
        if about.waitForExistence(timeout: 8) { about.tap(); sleep(1) }
        for _ in 0..<8 where !app.buttons["myMemories"].exists { app.swipeUp() }
        if app.buttons["myMemories"].waitForExistence(timeout: 5) {
            app.buttons["myMemories"].tap(); sleep(4); snap("private-layer")
            if app.buttons["memoriesDone"].waitForExistence(timeout: 5) { app.buttons["memoriesDone"].tap() }
        }
        app.tabBars.buttons["Chats"].tap()
        sleep(2); snap("chats")
        let chat = app.descendants(matching: .any)["chat-conv_sarah"].firstMatch
        if chat.waitForExistence(timeout: 8) { chat.tap() } else {
            app.descendants(matching: .any)["chat-conv_rahul"].firstMatch.tap()
        }
        sleep(3); snap("thread")
    }
}
