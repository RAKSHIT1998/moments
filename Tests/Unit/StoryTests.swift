import XCTest
import SwiftData
@testable import MOMENT

final class StoryComposerTests: XCTestCase {
    func mem(_ title: String, type: MemoryType = .conversation, daysAgo: Int, people: [String] = [], places: [String] = [], image: String? = nil, content: String = "", planStatus: PlanStatus? = nil, importance: Int = 50) -> StoryMemory {
        StoryMemory(id: UUID(), title: title, summary: "", content: content, type: type, createdAt: TestClock.now.adding(days: -daysAgo), importance: importance, isPinned: false, peopleNames: people, placeNames: places, imageRef: image, sourceType: content.isEmpty ? .photo : .screenshot, planTitle: planStatus == nil ? nil : title, planStatus: planStatus, promiseSummary: nil, promiseStatus: nil, promiseDirection: nil, taskDone: false, giftItem: nil, eventTitle: nil, interactions: 0)
    }

    var trip: [StoryMemory] {
        [
            mem("Photo", type: .photo, daysAgo: 9, people: ["Rahul"], places: ["Goa"], image: "a.jpg"),
            mem("Photo", type: .photo, daysAgo: 8, people: ["Sarah"], places: ["Goa"], image: "b.jpg", importance: 70),
            mem("Conversation with Rahul", daysAgo: 8, people: ["Rahul"], content: "Rahul: we're waking up at 7 tomorrow 😂\nYou: sure we are\nRahul: Palolem is unreal"),
            mem("Goa", type: .plan, daysAgo: 40, people: ["Rahul", "Sarah"], places: ["Goa"], planStatus: .completed),
            mem("Photo", type: .photo, daysAgo: 8, places: ["Palolem"], image: "c.jpg")
        ]
    }

    func testTripStoryHasCoverStatsQuotesAndClosing() {
        let t = MomentTemplate.find("drop.trip")!
        let out = StoryComposer(now: TestClock.now, calendar: TestClock.calendar).compose(template: t, memories: trip)
        XCTAssertTrue(out.title.hasPrefix("Goa '"), out.title)
        XCTAssertEqual(out.slides.first?.kind, .cover)
        XCTAssertEqual(out.slides.last?.kind, .closing)
        XCTAssertEqual(out.stats["people"], "2")
        XCTAssertEqual(out.stats["places"], "2")
        XCTAssertTrue(out.slides.contains { $0.kind == .quote && $0.title.contains("Palolem") || $0.kind == .list && $0.items.contains { $0.contains("waking up at 7") } }, "quotes from the chat should appear")
        XCTAssertTrue(out.subtitle.contains("5 memories"))
        XCTAssertTrue(out.slides.contains { $0.kind == .timeline && $0.items.count >= 2 })
        XCTAssertEqual(out.slides.last?.title, "You said you'd do it. You did.")
        // "Things I said I'd do" template lists plans with their real status.
        let said = StoryComposer(now: TestClock.now, calendar: TestClock.calendar).compose(template: MomentTemplate.find("said.would")!, memories: trip)
        XCTAssertTrue(said.slides.contains { $0.kind == .list && $0.title == "Things we said we'd do" && $0.items.first?.hasSuffix("|Done") == true })
    }

    func testNarrativeIsDataBacked() {
        let lines = StoryComposer(now: TestClock.now, calendar: TestClock.calendar).narrative(about: "Goa", memories: trip, plan: ("Goa", .completed, TestClock.now.adding(days: -40), TestClock.now.adding(days: -9)))
        XCTAssertTrue(lines.first?.contains("Rahul") == true)
        XCTAssertTrue(lines.contains { $0.contains("31 days before") }, lines.description)
        XCTAssertTrue(lines.contains("It happened."))
        XCTAssertTrue(lines.contains { $0.contains("waking up at 7") })
    }

    func testMonthRecapNeedsSubstance() {
        let engine = RecapEngine(calendar: TestClock.calendar)
        XCTAssertNil(engine.composeMonth(Array(trip.prefix(2)), for: TestClock.now, userName: nil))
        let many = (0..<6).map { mem("m\($0)", daysAgo: $0, people: ["Sarah"]) }
        XCTAssertNotNil(engine.composeMonth(many, for: TestClock.now, userName: nil))
    }

    func testCoreMemoryNeedsTwoSignals() {
        let m = mem("Best night ever 😂", daysAgo: 1, people: ["Rahul", "Sarah"], content: "best night ever 😂", importance: 40)
        XCTAssertTrue(CoreMemoryDetector.assess(m, relatedCount: 0, mentionsOfSamePlace: 0).isLikely)
        let plain = mem("Receipt", type: .reference, daysAgo: 1, importance: 20)
        XCTAssertFalse(CoreMemoryDetector.assess(plain, relatedCount: 0, mentionsOfSamePlace: 0).isLikely)
    }

    func testCommandRouterTell() {
        XCTAssertEqual(CommandRouter.route("Tell me about my Goa trip"), .tell("Goa"))
        XCTAssertEqual(CommandRouter.route("Summarize everything I know about Goa"), .tell("Goa"))
        XCTAssertEqual(CommandRouter.route("Remember that Rahul likes Japanese food"), .capture("Rahul likes Japanese food"))
    }
}

@MainActor
final class MomentPackageTests: XCTestCase {
    func testPackageRoundTripKeepsSlidesMediaAndSides() async throws {
        let env = makeEnvironment()
        let img = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { ctx in UIColor.systemIndigo.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300)) }
        let ref = try await env.media.store(img.jpegData(compressionQuality: 0.9)!, extension: "jpg")
        let story = MomentStory(title: "Goa '26", subtitle: "3 memories", kind: .drop, templateID: "drop.trip", slides: [StorySlide(kind: .cover, title: "Goa '26", body: "3 memories", mediaRef: ref), StorySlide(kind: .quote, title: "Palolem is unreal", body: "Rahul")], stats: ["memories": "3"], peopleNames: ["Rahul"])
        story.contributions = [StoryContribution(authorName: "Me", text: "Best trip.", mediaRef: ref, isMine: true)]
        env.storage.context.insert(story)

        let pkg = await MomentPackage.make(from: story, author: "Rakshit", media: env.media)
        let url = try pkg.write()
        XCTAssertEqual(url.pathExtension, "moment")
        let back = try MomentPackage.read(from: url)
        XCTAssertEqual(back.title, "Goa '26")
        XCTAssertEqual(back.slides.count, 2)
        XCTAssertNotNil(back.slides[0].mediaBase64)
        XCTAssertEqual(back.template.id, "drop.trip")

        let received = await back.materialize(media: env.media)
        XCTAssertTrue(received.isReceived)
        XCTAssertEqual(received.originAuthor, "Rakshit")
        XCTAssertNotNil(received.slides[0].mediaRef)
        XCTAssertEqual(received.contributions.first?.isMine, false, "the other person's side is never marked as mine")
        let loaded = await env.media.loadImage(received.slides[0].mediaRef!)
        XCTAssertNotNil(loaded)
    }

    func testImportMergesReturningPackageWithoutLosingMySide() async throws {
        let env = makeEnvironment()
        let story = MomentStory(title: "Night", kind: .drop, templateID: "drop.night", slides: [StorySlide(kind: .cover, title: "Night")])
        story.contributions = [StoryContribution(authorName: "Me", text: "mine", isMine: true)]
        env.storage.context.insert(story); env.storage.save()
        var pkg = await MomentPackage.make(from: story, author: "Friend", media: env.media)
        pkg.contributions.append(MomentPackage.Contribution(contribution: StoryContribution(authorName: "Friend", text: "theirs", isMine: true), mediaBase64: nil))
        pkg.reactions.append(StoryReaction(authorName: "Friend", reaction: .core))
        let url = try pkg.write()
        await env.stories.importPackage(at: url)
        let merged = env.stories.story(id: story.id)!
        XCTAssertEqual(merged.contributions.count, 2)
        XCTAssertTrue(merged.contributions.contains { $0.text == "mine" && $0.isMine })
        XCTAssertTrue(merged.contributions.contains { $0.text == "theirs" && !$0.isMine })
        XCTAssertEqual(merged.reactions.first?.reaction, .core)
        XCTAssertEqual(env.stories.pendingStoryID, story.id)
    }

    func testUnreadableFileIsRejected() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "junk.moment")
        try Data("{\"hello\":1}".utf8).write(to: url)
        XCTAssertThrowsError(try MomentPackage.read(from: url))
    }
}

@MainActor
final class StoryExporterTests: XCTestCase {
    func testRendersImageAndVideo() async throws {
        let env = makeEnvironment()
        let story = MomentStory(title: "Test", subtitle: "2 memories", kind: .custom, templateID: "drop.night", slides: [StorySlide(kind: .cover, title: "Test", body: "2 memories"), StorySlide(kind: .quote, title: "We said we'd go.", body: "Rahul"), StorySlide(kind: .closing, title: "Worth remembering.", body: "Made with MOMENT")])
        let theme = StoryTheme.from(.cinematic)
        let image = env.stories.exporter.render(story.slides[0], theme: theme, format: .story, image: nil)
        XCTAssertEqual((image?.size.width ?? 0) * (image?.scale ?? 0), 360 * 3, "exports at 1080 px wide")
        let urls = try await env.stories.exporter.exportImages(story, theme: theme, format: .square)
        XCTAssertEqual(urls.count, 3)
        let video = try await env.stories.exporter.exportVideo(story, theme: theme, format: .story) { _ in }
        let attrs = try FileManager.default.attributesOfItem(atPath: video.path())
        XCTAssertGreaterThan((attrs[.size] as? Int) ?? 0, 50_000, "video should have real frames")
        XCTAssertEqual(video.pathExtension, "mp4")
    }

    func testFreeTierExportBudget() {
        let env = makeEnvironment()
        let story = MomentStory(title: "T", kind: .custom, templateID: "drop.night")
        env.storage.context.insert(story)
        for _ in 0..<StoryService.freeExportsPerMonth { XCTAssertTrue(env.stories.canExport()); env.stories.noteExport(story, kind: "images") }
        XCTAssertFalse(env.stories.canExport())
        XCTAssertEqual(story.shareCount, StoryService.freeExportsPerMonth)
        XCTAssertEqual(story.visibility, .sharedWithPeople)
    }
}
