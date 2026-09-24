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
        app.descendants(matching: .any)["tab-Profile"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["profileHeader"].waitForExistence(timeout: 15))
        print("── PROFILE ──\n" + app.debugDescription)
        app.descendants(matching: .any)["tab-Chats"].firstMatch.tap()
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
}
