import XCTest
import SwiftData
@testable import MOMENT

/// Release gate: the app must stay usable at 10,000 memories.
final class ScaleTests: XCTestCase {
    private func corpus(_ n: Int) -> [MemorySnapshot] {
        let people = ["Sarah", "Rahul", "Priya", "Arjun", "Meera", "Karan"]
        let places = ["Goa", "Bali", "Tosaka", "Toit", "Manali", "Paris"]
        let types: [MemoryType] = [.giftIdea, .promise, .plan, .place, .task, .conversation, .reference, .idea]
        return (0..<n).map { i in
            let p = people[i % people.count], pl = places[i % places.count], t = types[i % types.count]
            return MemorySnapshot(id: UUID(), title: "\(p) — \(t.label) about \(pl) #\(i)", summary: "\(p) mentioned \(pl) in message \(i).", content: "Rahul: ok let's do \(pl) some time. \(p) wants that thing #\(i)", memoryType: t, createdAt: TestClock.now.adding(days: -(i % 400)), importance: i % 100, confidence: .high, peopleNames: [p], placeNames: [pl], tags: [], sourceType: .screenshot, referencedDateStart: nil, referencedDateEnd: nil, referencedPrecision: nil, isPinned: false)
        }
    }

    func testSearchTenThousandMemoriesStaysUsable() {
        let memories = corpus(10_000)
        let engine = SearchEngine(context: TestClock.context)
        _ = engine.search("warm up", in: memories) // loads the embedding model + fills the cache
        let start = Date()
        let r = engine.search("What did Sarah want?", in: memories)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(r.hits.isEmpty)
        XCTAssertLessThan(elapsed, 3.0, "search over 10k memories took \(elapsed)s")
    }

    func testSurfaceEngineTenThousandCandidates() {
        let engine = SurfaceEngine(now: TestClock.now, calendar: TestClock.calendar)
        let candidates = (0..<10_000).map { i in
            SurfaceEngine.Candidate(memoryID: UUID(), title: "t\(i)", summary: "s", type: .promise, importance: i % 100, createdAt: TestClock.now.adding(days: -(i % 90)), lastSurfacedAt: nil, reminderAt: nil, referencedStart: nil, referencedPrecision: nil, personName: "P\(i % 50)", personBirthday: nil, promiseStatus: i % 3 == 0 ? .pending : .completed, promiseDirection: .personOwes, promiseDue: nil, planStatus: nil, planAnchor: nil, giftStatus: nil, giftItem: nil, eventDate: nil, eventIsAnnual: false, isPinned: false, userInteractions: 0, openGiftIdeasForPerson: 0)
        }
        let start = Date()
        let recs = engine.recommend(candidates, limit: 6)
        XCTAssertEqual(recs.count, 6)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.0, "SurfaceEngine over 10k candidates was slow")
    }

    @MainActor
    func testOnDiskStoreWithThousandsOfMemories() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "scale-\(UUID().uuidString)")
        let storage = try StorageService(directory: dir)
        let sarah = Person(displayName: "Sarah"); storage.context.insert(sarah)
        let start = Date()
        for i in 0..<3_000 {
            let m = Memory(title: "Memory \(i) about Goa", summary: "Sarah mentioned Goa \(i)", content: "content \(i)", memoryType: i % 2 == 0 ? .plan : .place, importance: i % 100, confidence: .high, reviewStatus: .saved, source: Source(type: .screenshot))
            m.people.append(sarah)
            m.refreshCaches()
            storage.context.insert(m)
            if i % 500 == 0 { storage.save() }
        }
        storage.save()
        let insertTime = Date().timeIntervalSince(start)
        XCTAssertLessThan(insertTime, 30, "inserting 3k memories took \(insertTime)s")

        // The app warms the language models at launch; do the same so we time the index, not model loading.
        _ = SearchEngine(context: storage.analysisContext()).parse("warm up Goa")
        let t1 = Date()
        let snapshots = try await SearchIndex(modelContainer: storage.container).snapshots()
        let indexTime = Date().timeIntervalSince(t1)
        XCTAssertEqual(snapshots.count, 3_000)
        XCTAssertEqual(snapshots.first?.peopleNames, ["Sarah"], "denormalized names must be indexed")
        let t2 = Date()
        let ctx = storage.analysisContext()
        let ctxTime = Date().timeIntervalSince(t2)
        let t3 = Date()
        let r = SearchEngine(context: ctx).search("When did we talk about Goa?", in: snapshots)
        let searchTime = Date().timeIntervalSince(t3)
        print("SCALE index=\(indexTime)s context=\(ctxTime)s search=\(searchTime)s")
        XCTAssertFalse(r.hits.isEmpty)
        XCTAssertLessThan(indexTime, 6, "building the index for 3k on-disk memories took \(indexTime)s")
        XCTAssertLessThan(searchTime, 4, "search over 3k took \(searchTime)s")

        // Survives reopening from disk.
        let reopened = try StorageService(directory: dir)
        XCTAssertEqual(try reopened.context.fetchCount(FetchDescriptor<Memory>()), 3_000)
    }
}
