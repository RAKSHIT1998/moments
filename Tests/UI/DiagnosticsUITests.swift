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
}
