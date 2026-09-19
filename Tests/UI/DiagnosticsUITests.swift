import XCTest

/// Dumps the accessibility tree of a few screens so failing selectors can be fixed from the log.
final class DiagnosticsUITests: XCTestCase {
    func testDumpTrees() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-reset", "-demo"]
        app.launch()
        XCTAssertTrue(app.otherElements["feedMoment-m_goa"].firstMatch.waitForExistence(timeout: 30))
        let card = app.otherElements["feedMoment-m_goa"].firstMatch
        print("DIAG-CARD-START\n\(card.debugDescription)\nDIAG-CARD-END")
        card.buttons["open-m_goa"].firstMatch.tap()
        sleep(3)
        print("DIAG-AFTER-OPEN-START\n\(app.debugDescription.prefix(6000))\nDIAG-AFTER-OPEN-END")
        app.tabBars.buttons["Profile"].tap()
        sleep(3)
        let tree = app.debugDescription
        let lines = tree.split(separator: "\n").filter { $0.contains("Privacy") || $0.contains("safetyLink") || $0.contains("Edit profile") || $0.contains("NavigationBar") }
        print("DIAG-PROFILE-START\n\(lines.joined(separator: "\n"))\nDIAG-PROFILE-END")
    }
}
