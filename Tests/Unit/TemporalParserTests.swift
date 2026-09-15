import XCTest
@testable import MOMENT

final class TemporalParserTests: XCTestCase {
    let parser = TemporalParser(now: TestClock.now, calendar: TestClock.calendar)

    func testTomorrow() {
        let h = parser.primary(in: "call Rahul tomorrow")!
        XCTAssertEqual(h.precision, .day)
        XCTAssertEqual(TestClock.calendar.component(.day, from: h.start), 14)
        XCTAssertTrue(h.isFuture)
    }

    func testTomorrowWithTime() {
        let h = parser.primary(in: "dentist tomorrow at 5")!
        XCTAssertEqual(h.precision, .exact)
        XCTAssertEqual(TestClock.calendar.component(.hour, from: h.start), 17)
    }

    func testNextFriday() {
        // 13 Sep 2026 is a Sunday. "next friday" → Friday 25 Sep? "next" skips the current week's Friday (18th) only if it's within this calendar week.
        let h = parser.primary(in: "let's meet next friday")!
        XCTAssertEqual(TestClock.calendar.component(.weekday, from: h.start), 6)
        XCTAssertTrue(h.start > TestClock.now)
    }

    func testMonthOnly() {
        let h = parser.primary(in: "Bro let's go Goa in December 😂")!
        XCTAssertEqual(h.precision, .month)
        XCTAssertEqual(TestClock.calendar.component(.month, from: h.start), 12)
        XCTAssertEqual(TestClock.calendar.component(.year, from: h.start), 2026)
        XCTAssertEqual(h.rawText, "december")
    }

    func testPastMonthRollsToNextYear() {
        let h = parser.primary(in: "we should go in March")!
        XCTAssertEqual(TestClock.calendar.component(.year, from: h.start), 2027)
    }

    func testMonthWithDay() {
        let h = parser.primary(in: "Sarah's birthday is September 22")!
        XCTAssertEqual(h.precision, .day)
        XCTAssertEqual(TestClock.calendar.dateComponents([.month, .day], from: h.start), DateComponents(month: 9, day: 22))
    }

    func testInTwoWeeks() {
        let h = parser.primary(in: "flight in two weeks")!
        XCTAssertEqual(h.precision, .week)
        XCTAssertEqual(TestClock.calendar.dateComponents([.day], from: TestClock.calendar.startOfDay(for: TestClock.now), to: h.start).day, 14)
    }

    func testNextMonthAndSometimeNextYear() {
        XCTAssertEqual(parser.primary(in: "next month")?.precision, .month)
        let y = parser.primary(in: "sometime next year")!
        XCTAssertEqual(y.precision, .vague)
        XCTAssertEqual(TestClock.calendar.component(.year, from: y.start), 2027)
    }

    func testVague() {
        XCTAssertEqual(parser.primary(in: "we should do this later")?.precision, .vague)
        XCTAssertNil(parser.primary(in: "I love this song"))
    }

    func testMayIsNotAlwaysAMonth() {
        XCTAssertNil(parser.primary(in: "we may go"))
        XCTAssertEqual(parser.primary(in: "we go in May")?.precision, .month)
    }

    func testMyBirthdayNeedsProfile() {
        XCTAssertNil(parser.primary(in: "for my birthday"))
        let p2 = TemporalParser(now: TestClock.now, calendar: TestClock.calendar, userBirthday: TestClock.date(1995, 10, 2))
        let h = p2.primary(in: "for my birthday")!
        XCTAssertEqual(TestClock.calendar.dateComponents([.month, .day], from: h.start), DateComponents(month: 10, day: 2))
    }
}
