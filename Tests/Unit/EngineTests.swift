import XCTest
@testable import MOMENT

final class ImportanceEngineTests: XCTestCase {
    func testDeadlineTaskIsHigh() {
        let hint = TemporalHint(start: TestClock.now.adding(days: 1), end: TestClock.now.adding(days: 1), precision: .day, rawText: "tomorrow", isFuture: true)
        let m = ExtractedMemory(title: "Renew passport", summary: "", content: "I need to renew passport tomorrow", memoryType: .task, confidence: 0.9, temporal: hint)
        XCTAssertGreaterThanOrEqual(ImportanceEngine.score(m, now: TestClock.now), 75)
    }
    func testCasualPlaceIsLowMedium() {
        let m = ExtractedMemory(title: "Nice place", summary: "", content: "That restaurant looked nice", memoryType: .place, confidence: 0.6)
        let s = ImportanceEngine.score(m, now: TestClock.now)
        XCTAssertLessThan(s, 55); XCTAssertGreaterThan(s, 15)
    }
    func testPinBoosts() {
        XCTAssertGreaterThan(ImportanceEngine.rescore(base: 40, isPinned: true, userEdited: false, ageDays: 1, hasOpenItem: false), 60)
    }
}

final class SurfaceEngineTests: XCTestCase {
    let engine = SurfaceEngine(now: TestClock.now, calendar: TestClock.calendar)

    func candidate(_ mutate: (inout SurfaceEngine.Candidate) -> Void) -> SurfaceEngine.Candidate {
        var c = SurfaceEngine.Candidate(memoryID: UUID(), title: "Title", summary: "Summary", type: .reference, importance: 40, createdAt: TestClock.now.adding(days: -5), lastSurfacedAt: nil, reminderAt: nil, referencedStart: nil, referencedPrecision: nil, personName: nil, personBirthday: nil, promiseStatus: nil, promiseDirection: nil, promiseDue: nil, planStatus: nil, planAnchor: nil, giftStatus: nil, giftItem: nil, eventDate: nil, eventIsAnnual: false, isPinned: false, userInteractions: 0, openGiftIdeasForPerson: 0)
        mutate(&c)
        return c
    }

    func testPendingPromiseBecomesFollowUp() {
        let c = candidate { $0.title = "Rahul will send you the property contact"; $0.type = .promise; $0.promiseStatus = .pending; $0.promiseDirection = .personOwes; $0.personName = "Rahul"; $0.createdAt = TestClock.now.adding(days: -2); $0.importance = 70 }
        let r = engine.evaluate(c)!
        XCTAssertEqual(r.category, .followUp)
        XCTAssertTrue(r.headline.contains("Rahul said they'd send you the property contact"), r.headline)
        XCTAssertEqual(r.actionKind, .followUp)
    }

    func testBirthdayInSevenDaysNotifies() {
        let c = candidate { $0.title = "Sarah's birthday"; $0.type = .event; $0.eventDate = TestClock.date(1996, 9, 20); $0.eventIsAnnual = true; $0.personName = "Sarah"; $0.openGiftIdeasForPerson = 1 }
        let r = engine.evaluate(c)!
        XCTAssertEqual(r.category, .upcoming)
        XCTAssertTrue(r.notificationAllowed)
        XCTAssertEqual(r.surfaceType, .both)
        XCTAssertTrue(r.headline.contains("in 7 days"))
        XCTAssertEqual(r.actionKind, .viewGift)
    }

    func testOldReferenceIsNotResurfaced() {
        let c = candidate { $0.createdAt = TestClock.now.adding(days: -200) }
        XCTAssertNil(engine.evaluate(c))
    }

    func testPlanApproachingWindow() {
        let c = candidate { $0.title = "Goa — December"; $0.type = .plan; $0.planStatus = .discussed; $0.planAnchor = TestClock.date(2026, 10, 1); $0.referencedPrecision = .month; $0.personName = "Rahul" }
        let r = engine.evaluate(c)!
        XCTAssertEqual(r.category, .plan)
        XCTAssertEqual(r.actionKind, .continuePlan)
    }

    func testRecentlyShownIsDemoted() {
        let fresh = candidate { $0.promiseStatus = .pending; $0.type = .promise; $0.importance = 70 }
        let shown = candidate { $0.promiseStatus = .pending; $0.type = .promise; $0.importance = 70; $0.lastSurfacedAt = TestClock.now.adding(days: -2) }
        XCTAssertGreaterThan(engine.evaluate(fresh)!.priority, engine.evaluate(shown)!.priority)
    }

    func testLimitsAndPerPersonCap() {
        let many = (0..<10).map { i in candidate { $0.promiseStatus = .pending; $0.type = .promise; $0.importance = 60 + i; $0.personName = "Rahul" } }
        let recs = engine.recommend(many, limit: 6)
        XCTAssertEqual(recs.count, 2, "one person shouldn't fill the feed")
    }
}

final class NotificationBudgetTests: XCTestCase {
    func rec(_ p: Double, allowed: Bool = true, at: Date? = nil) -> SurfaceEngine.Recommendation {
        SurfaceEngine.Recommendation(memoryID: UUID(), category: .followUp, priority: p, headline: "h", detail: nil, reason: "", surfaceType: .both, recommendedTime: at, notificationAllowed: allowed, personName: nil, actionKind: .open)
    }
    func testBudgetPerDay() {
        let recs = [rec(0.9), rec(0.8), rec(0.7), rec(0.95, allowed: false)]
        let planned = NotificationBudget.plan(recs, budgetPerDay: 2, now: TestClock.now, calendar: TestClock.calendar)
        XCTAssertEqual(planned.count, 2)
        XCTAssertEqual(planned.map { $0.0.priority }, [0.9, 0.8])
    }
    func testZeroBudget() {
        XCTAssertTrue(NotificationBudget.plan([rec(0.9)], budgetPerDay: 0, now: TestClock.now).isEmpty)
    }
    func testDifferentDaysGetSeparateBudgets() {
        let recs = [rec(0.9, at: TestClock.now.adding(days: 1)), rec(0.8, at: TestClock.now.adding(days: 1)), rec(0.7, at: TestClock.now.adding(days: 2))]
        XCTAssertEqual(NotificationBudget.plan(recs, budgetPerDay: 2, now: TestClock.now, calendar: TestClock.calendar).count, 3)
    }
}

final class SearchEngineTests: XCTestCase {
    func snap(_ title: String, _ summary: String, type: MemoryType, people: [String] = [], places: [String] = [], daysAgo: Int = 3) -> MemorySnapshot {
        MemorySnapshot(id: UUID(), title: title, summary: summary, content: summary, memoryType: type, createdAt: TestClock.now.adding(days: -daysAgo), importance: 50, confidence: .high, peopleNames: people, placeNames: places, tags: [], sourceType: .manual, referencedDateStart: nil, referencedDateEnd: nil, referencedPrecision: nil, isPinned: false)
    }
    lazy var corpus: [MemorySnapshot] = {
        [
            snap("Sarah wants New Balance 530", "Sarah mentioned wanting New Balance 530. Saved as a gift idea.", type: .giftIdea, people: ["Sarah"], daysAgo: 23),
            snap("Rahul will send you the property contact", "Rahul said they'd send you that property guy's number. Pending.", type: .promise, people: ["Rahul"], daysAgo: 2),
            snap("Goa — December", "Rahul suggested going to Goa in December. Not confirmed yet.", type: .plan, people: ["Rahul"], places: ["Goa"], daysAgo: 11),
            snap("Tosaka — restaurant", "Sarah mentioned Tosaka while talking about Japanese food.", type: .place, people: ["Sarah"], places: ["Tosaka"], daysAgo: 27),
            snap("Renew passport", "Tomorrow.", type: .task, daysAgo: 1)
        ]
    }()
    let engine = SearchEngine(context: TestClock.context)

    func testWhatDidSarahWant() {
        let r = engine.search("What did Sarah want for her birthday?", in: corpus)
        XCTAssertEqual(r.interpretedIntent, .whatDidPersonWant)
        XCTAssertEqual(r.hits.first.flatMap { h in corpus.first { $0.id == h.memoryID } }?.memoryType, .giftIdea)
        XCTAssertTrue(r.answer?.contains("New Balance") == true, r.answer ?? "nil")
    }
    func testWhatDidRahulPromise() {
        let r = engine.search("What did Rahul promise me?", in: corpus)
        XCTAssertEqual(r.interpretedIntent, .whatDidPersonPromise)
        XCTAssertTrue(r.answer?.contains("property") == true, r.answer ?? "nil")
    }
    func testWhenDidWeTalkAboutGoa() {
        let r = engine.search("When did we talk about Goa?", in: corpus)
        XCTAssertEqual(r.interpretedIntent, .whenDidWeTalkAbout)
        XCTAssertTrue(r.answer?.contains("Goa") == true)
        XCTAssertTrue(r.hits.first?.reason.lowercased().contains("goa") == true, r.hits.first?.reason ?? "")
    }
    func testRestaurantsList() {
        let r = engine.search("What restaurants did I save?", in: corpus)
        XCTAssertEqual(r.interpretedIntent, .listOfType)
        XCTAssertTrue(r.answer?.contains("Tosaka") == true, r.answer ?? "nil")
    }
    func testWhoMentionedShoes() {
        let r = engine.search("What was that shoe brand Sarah liked?", in: corpus)
        XCTAssertEqual(r.hits.first.flatMap { h in corpus.first { $0.id == h.memoryID } }?.title, "Sarah wants New Balance 530")
    }
    func testUnsupportedQueryHasNoAnswer() {
        let r = engine.search("What is the capital of France?", in: corpus)
        XCTAssertNil(r.answer)
    }
}

final class SubscriptionStateTests: XCTestCase {
    @MainActor func testFreeLimit() {
        let s = SubscriptionService()
        XCTAssertTrue(s.canCreateMemory(currentCount: 0))
        XCTAssertTrue(s.canCreateMemory(currentCount: 99))
        XCTAssertFalse(s.canCreateMemory(currentCount: 100))
    }
}
