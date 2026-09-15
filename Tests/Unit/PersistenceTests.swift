import XCTest
import SwiftData
@testable import MOMENT

@MainActor
final class PersistenceTests: XCTestCase {
    func testPipelinePersistsEntitiesAndRelationships() async throws {
        let env = makeEnvironment()
        let o1 = try await env.importer.run(CaptureInput(payload: .text("Rahul\n\nRahul: Bro let's go Goa in December 😂\n9:14 PM"), sourceType: .screenshot, createdAt: TestClock.now.adding(days: -11)))
        env.actions.saveAll(o1.memories)
        let o2 = try await env.importer.run(CaptureInput(payload: .text("Rahul\n\nRahul: Remind me I'll send you that property guy's number\nDelivered"), sourceType: .screenshot, createdAt: TestClock.now.adding(days: -2)))
        env.actions.saveAll(o2.memories)

        let people = env.storage.fetchPeople()
        XCTAssertEqual(people.count, 1, "Rahul should resolve to one person: \(people.map(\.displayName))")
        let rahul = people[0]
        XCTAssertEqual(rahul.memories.count, 2)
        XCTAssertEqual(rahul.pendingPromises.count, 1)
        XCTAssertEqual(rahul.activePlans.count, 1)
        XCTAssertEqual(env.storage.fetchPlans().first?.location, "Goa")
        XCTAssertNotNil(o2.memories.first?.source, "provenance is mandatory")
        XCTAssertEqual(o2.memories.first?.source?.type, .screenshot)
        XCTAssertFalse(env.storage.fetchRelations(for: o2.memories[0].id).isEmpty, "same-person relation expected")
    }

    func testSameDestinationMergesIntoOnePlan() async throws {
        let env = makeEnvironment()
        for text in ["Let's go to Goa in December", "Rahul is in for Goa", "we discussed flights to Goa"] {
            let o = try await env.importer.run(CaptureInput(payload: .text(text), sourceType: .manual))
            env.actions.saveAll(o.memories)
        }
        XCTAssertEqual(env.storage.fetchPlans().filter { $0.status.isActive }.count, 1, env.storage.fetchPlans().map(\.title).description)
    }

    func testInboxThenSaveThenDismiss() async throws {
        let env = makeEnvironment()
        let o = try await env.importer.run(CaptureInput(payload: .text("Sarah wants those Sony headphones"), sourceType: .manual))
        XCTAssertEqual(env.storage.fetchInbox().count, 1)
        XCTAssertEqual(env.storage.memoryCount, 0)
        env.actions.save(o.memories[0])
        XCTAssertEqual(env.storage.fetchInbox().count, 0)
        XCTAssertEqual(env.storage.memoryCount, 1)
        env.actions.dismiss(o.memories[0])
        XCTAssertEqual(env.storage.memoryCount, 0)
        XCTAssertTrue(env.storage.fetchGiftIdeas().allSatisfy(\.isDeleted))
    }

    func testPersonCorrectionUpdatesEntityAndFutureResolution() async throws {
        let env = makeEnvironment()
        let o = try await env.importer.run(CaptureInput(payload: .text("Sarah\n\nSarah: I really want these New Balance shoes"), sourceType: .screenshot))
        env.actions.saveAll(o.memories)
        let m = o.memories[0]
        XCTAssertEqual(m.people.first?.displayName, "Sarah")
        env.actions.correctPerson(in: m, from: m.people.first, to: "Priya")
        XCTAssertEqual(m.people.map(\.displayName), ["Priya"])
        XCTAssertEqual(m.giftIdeas.first?.person?.displayName, "Priya")
        XCTAssertTrue(m.title.contains("Priya"))
        XCTAssertFalse(env.storage.fetchCorrections().isEmpty, "correction stored for the feedback loop")
        let ctx = env.storage.analysisContext()
        XCTAssertEqual(ctx.personCorrections["sarah"], m.people.first?.id)
    }

    func testMergePreservesSources() async throws {
        let env = makeEnvironment()
        let a = try await env.importer.run(CaptureInput(payload: .text("Let's go to Goa in December"), sourceType: .manual)).memories[0]
        let b = try await env.importer.run(CaptureInput(payload: .text("Goa trip - Rahul wants to go in December too"), sourceType: .manual)).memories[0]
        env.actions.saveAll([a, b])
        let merged = env.actions.merge([a, b])
        XCTAssertEqual(merged?.id, a.id)
        XCTAssertTrue(b.isArchived); XCTAssertFalse(b.isDeleted)
        XCTAssertNotNil(b.source)
        XCTAssertTrue(env.storage.fetchRelations(for: a.id).contains { $0.kind == .mergedFrom })
    }

    func testExportContainsEverything() async throws {
        let env = makeEnvironment()
        let o = try await env.importer.run(CaptureInput(payload: .text("Sarah's birthday is September 22."), sourceType: .manual))
        env.actions.saveAll(o.memories)
        let exporter = ExportService(storage: env.storage)
        let bundle = exporter.makeBundle()
        XCTAssertEqual(bundle.memories.count, 1)
        XCTAssertEqual(bundle.people.first?.displayName, "Sarah")
        XCTAssertNotNil(bundle.people.first?.birthday)
        let url = try exporter.export(.json)
        XCTAssertGreaterThan((try Data(contentsOf: url)).count, 100)
        XCTAssertTrue(exporter.csv(bundle).contains("Sarah"))
        XCTAssertTrue(exporter.plainText(bundle).contains("birthday"))
    }

    func testDeleteEverything() async throws {
        let env = makeEnvironment()
        let o = try await env.importer.run(CaptureInput(payload: .text("Rahul said he'd send the number"), sourceType: .manual))
        env.actions.saveAll(o.memories)
        try await env.lifecycle.deleteEverything()
        XCTAssertEqual(env.storage.memoryCount, 0)
        XCTAssertTrue(env.storage.fetchPeople().isEmpty)
        XCTAssertTrue(env.storage.fetchPromises().isEmpty)
        let size = await env.lifecycle.mediaSize()
        XCTAssertEqual(size, 0)
    }

    func testDeleteMemoryRemovesOrphans() async throws {
        let env = makeEnvironment()
        let o = try await env.importer.run(CaptureInput(payload: .text("Sarah wants those Sony headphones"), sourceType: .manual))
        env.actions.saveAll(o.memories)
        await env.actions.delete(o.memories[0])
        XCTAssertEqual(env.storage.memoryCount, 0)
        XCTAssertTrue(env.storage.fetchGiftIdeas().allSatisfy(\.isDeleted))
    }

    func testMockProviderIsUsedWhenInjected() async throws {
        let env = makeEnvironment()
        let mock = MockIntelligenceProvider(analysisResult: AnalysisResult(memories: [ExtractedMemory(title: "Mocked", summary: "s", content: "c", memoryType: .idea, confidence: 0.9)], confidence: 0.9, normalizedText: "c"))
        env.importer.providerOverride = mock
        let o = try await env.importer.run(CaptureInput(payload: .text("anything"), sourceType: .manual))
        XCTAssertEqual(o.memories.first?.title, "Mocked")
        XCTAssertEqual(mock.analyzeCalls.count, 1)
    }

    func testSurfaceServiceBuildsFeedAndWidgetSnapshot() async throws {
        let env = makeEnvironment()
        let o = try await env.importer.run(CaptureInput(payload: .text("Rahul\n\nRahul: Remind me I'll send you that property guy's number"), sourceType: .screenshot, createdAt: Date.now.adding(days: -3)))
        env.actions.saveAll(o.memories)
        await env.surface.refresh(scheduleNotifications: false)
        XCTAssertEqual(env.surface.feed.first?.recommendation.category, .followUp)
        XCTAssertNotNil(o.memories[0].lastSurfacedAt)
    }
}

@MainActor
final class OnDiskPersistenceTests: XCTestCase {
    func testDeleteEverythingOnDiskStoreClearsAllTables() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString)")
        let storage = try StorageService(directory: dir)
        let env = AppEnvironment(storage: storage, settings: SettingsStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!), mediaDirectory: dir.appending(path: "media"))
        for text in ["Rahul\n\nRahul: Remind me I'll send you that property guy's number", "Sarah's birthday is September 22.", "Let's go to Goa in December", "Sarah\n\nSarah: I really want these New Balance 530"] {
            let o = try await env.importer.run(CaptureInput(payload: .text(text), sourceType: .screenshot))
            env.actions.saveAll(o.memories)
        }
        XCTAssertGreaterThan(storage.memoryCount, 3)
        try storage.deleteEverything()
        XCTAssertEqual(try storage.context.fetchCount(FetchDescriptor<Memory>()), 0)
        XCTAssertEqual(try storage.context.fetchCount(FetchDescriptor<Person>()), 0)
        XCTAssertEqual(try storage.context.fetchCount(FetchDescriptor<Promise>()), 0)
        XCTAssertEqual(try storage.context.fetchCount(FetchDescriptor<Plan>()), 0)
        XCTAssertEqual(try storage.context.fetchCount(FetchDescriptor<Source>()), 0)
        XCTAssertEqual(try storage.context.fetchCount(FetchDescriptor<MemoryRelation>()), 0)
        // Reopen the same store from disk: still empty.
        let reopened = try StorageService(directory: dir)
        XCTAssertEqual(try reopened.context.fetchCount(FetchDescriptor<Memory>()), 0)
        XCTAssertEqual(try reopened.context.fetchCount(FetchDescriptor<Person>()), 0)
    }
}
