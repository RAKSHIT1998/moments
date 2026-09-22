import AVFoundation
import UIKit
import XCTest
@testable import MOMENT

final class FeedRankerTests: XCTestCase {
    func moment(_ id: String, creator: String, members: [String], hoursAgo: Double, vis: MomentVisibility = .group, contributions: Int = 0, live: Bool = false) -> SocialMoment {
        SocialMoment(id: id, creatorID: creator, creatorName: creator, title: id, description: "", coverRef: nil, createdAt: TestClock.now.addingTimeInterval(-hoursAgo * 3600), startAt: nil, endAt: nil, locationName: nil, coarsePlace: nil, visibility: vis, memberIDs: members, memberNames: members, contributionCount: contributions, mediaCount: 0, commentCount: 0, reactionCounts: [:], shareCount: 0, isLive: live, templateID: nil, remixedFromID: nil, shareURL: nil, allowsReshare: true, allowsDownload: true, allowsContributions: true)
    }

    func testMomentsIWasPartOfOutrankStrangers() {
        var g = RelationshipGraph(); g.following = ["friend"]; g.close = ["friend"]
        let mine = moment("mine", creator: "friend", members: ["friend", "me"], hoursAgo: 48)
        let stranger = moment("stranger", creator: "x", members: ["x"], hoursAgo: 1, vis: .publicAll, contributions: 10)
        let ranked = FeedRanker.rank([stranger, mine], me: "me", graph: g, seen: [], now: TestClock.now)
        XCTAssertEqual(ranked.first?.moment.id, "mine")
        XCTAssertTrue(ranked.first!.reason.contains("You were there"))
    }

    func testBlockedAndMutedNeverAppearAndSeenIsDamped() {
        var g = RelationshipGraph(); g.blocked = ["bad"]; g.muted = ["loud"]
        let a = moment("a", creator: "bad", members: ["bad", "me"], hoursAgo: 1)
        let b = moment("b", creator: "loud", members: ["loud"], hoursAgo: 1, vis: .publicAll)
        let c = moment("c", creator: "ok", members: ["ok"], hoursAgo: 1, vis: .publicAll)
        let d = moment("d", creator: "ok", members: ["ok"], hoursAgo: 1, vis: .publicAll)
        let ranked = FeedRanker.rank([a, b, c, d], me: "me", graph: g, seen: ["c"], now: TestClock.now)
        XCTAssertEqual(ranked.map(\.moment.id), ["d", "c"])
    }

    func testLiveMomentsGetABoost() {
        let live = moment("live", creator: "p", members: ["p"], hoursAgo: 5, vis: .publicAll, live: true)
        let old = moment("old", creator: "p", members: ["p"], hoursAgo: 5, vis: .publicAll)
        let ranked = FeedRanker.rank([old, live], me: "me", graph: RelationshipGraph(), seen: [], now: TestClock.now)
        XCTAssertEqual(ranked.first?.moment.id, "live")
        XCTAssertTrue(ranked.first!.reason.contains("Live"))
    }

    func testRelationshipStrengthComesFromSharedExperience() {
        var g = RelationshipGraph(); g.sharedMomentCounts = ["a": 3]; g.following = ["b"]
        XCTAssertGreaterThan(g.strength("a"), g.strength("b"))
        g.blocked = ["a"]
        XCTAssertEqual(g.strength("a"), 0)
    }
}

final class MomentTimelineTests: XCTestCase {
    func c(_ id: String, minutes: Double, author: String = "a") -> Contribution {
        Contribution(id: id, momentID: "m", authorID: author, authorName: author, kind: .photo, media: nil, caption: "", createdAt: TestClock.now, originalTimestamp: TestClock.now.addingTimeInterval(minutes * 60), reactionCounts: [:], commentCount: 0, uploadState: .uploaded)
    }

    func testGroupsByRealTimestampsAcrossAuthors() {
        let entries = MomentTimeline.build([c("1", minutes: 0), c("3", minutes: 200, author: "b"), c("2", minutes: 20, author: "b"), c("4", minutes: 230)])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].contributions.map(\.id), ["1", "2"])
        XCTAssertEqual(entries[1].contributions.map(\.id), ["3", "4"])
    }

    func testFallsBackToUploadTimeWithoutExif() {
        var x = c("x", minutes: 0); x.originalTimestamp = nil
        XCTAssertEqual(MomentTimeline.build([x]).first?.time, TestClock.now)
    }
}

final class ContentModerationTests: XCTestCase {
    func testBlocksAbuseAndSpamButNotNormalTalk() {
        XCTAssertEqual(ContentModeration.check("Best night ever, we are going back"), .ok)
        XCTAssertEqual(ContentModeration.check("free crypto dm for promo"), .spam)
        if case .blocked = ContentModeration.check("kys loser") {} else { XCTFail("should block") }
        XCTAssertEqual(ContentModeration.check("see http://a.com http://b.com http://c.com"), .spam)
    }
}

@MainActor
final class InMemoryBackendFlowTests: XCTestCase {
    func makeSocial() async -> (AppEnvironment, InMemoryBackend) {
        let backend = InMemoryBackend(displayName: "Rakshit")
        await backend.seedDemo()
        let env = AppEnvironment(storage: try! StorageService(inMemory: true), settings: SettingsStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!), mediaDirectory: FileManager.default.temporaryDirectory.appending(path: "test-media-\(UUID().uuidString)"), backend: backend)
        await env.social.start()
        return (env, backend)
    }

    func testCreateMomentInviteAndOtherPersonAddsTheirSide() async throws {
        let (env, backend) = await makeSocial()
        XCTAssertTrue(env.social.isSignedIn)
        let img = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { ctx in UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 400)) }.jpegData(compressionQuality: 0.8)!
        let m = await env.social.createMoment(SocialService.NewMomentInput(title: "Test night", photos: [img, img], note: "was great"))
        let moment = try XCTUnwrap(m)
        XCTAssertEqual(moment.creatorID, "me")
        XCTAssertNotNil(moment.coverRef)
        // Uploads drain through the queue.
        for _ in 0..<50 where env.social.queue.pendingCount > 0 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(env.social.queue.pendingCount, 0)
        let loaded = await env.social.loadMoment(moment.id)
        XCTAssertEqual(loaded?.contributionCount, 3)
        XCTAssertEqual(loaded?.mediaCount, 2)

        // Invite Rahul → real (in-memory) share link, Rahul is a member.
        let sharedBefore = env.analytics.count(.momentShared), startedBefore = env.analytics.sharedMomentsCreated
        let url = await env.social.shareLink(momentID: moment.id, with: ["u_rahul"])
        XCTAssertNotNil(url)
        XCTAssertTrue(env.social.moments[moment.id]!.memberIDs.contains("u_rahul"))
        XCTAssertEqual(env.analytics.count(.momentShared), sharedBefore + 1)
        XCTAssertEqual(env.analytics.sharedMomentsCreated, startedBefore + 1, "north star: a Moment became shared")

        // Rahul adds his side; it's attributed to him, not me.
        try await backend.acting(as: "u_rahul") { b in
            _ = try await b.addContribution(Contribution(id: "r1", momentID: moment.id, authorID: "u_rahul", authorName: "Rahul Mehta", kind: .text, media: nil, caption: "told you", createdAt: .now, originalTimestamp: nil, reactionCounts: [:], commentCount: 0, uploadState: .pending), mediaData: nil)
        }
        await env.social.loadMoment(moment.id)
        let sides = env.social.allContributions(moment.id)
        XCTAssertEqual(sides.count, 4)
        XCTAssertTrue(sides.contains { $0.authorID == "u_rahul" && $0.caption == "told you" })
        // A stranger can't add to a group Moment.
        do {
            try await backend.acting(as: "u_dev") { b in
                _ = try await b.addContribution(Contribution(id: "d1", momentID: moment.id, authorID: "u_dev", authorName: "Dev", kind: .text, media: nil, caption: "hi", createdAt: .now, originalTimestamp: nil, reactionCounts: [:], commentCount: 0, uploadState: .pending), mediaData: nil)
            }
            XCTFail("stranger should be rejected")
        } catch { if case SocialError.notAllowed = error {} else { XCTFail("expected notAllowed, got \(error)") } }
    }

    func testAcceptInviteLinkJoinsMoment() async throws {
        let (env, backend) = await makeSocial()
        // Rahul creates a Moment and shares a link; I open it.
        var link: URL?
        try await backend.acting(as: "u_rahul") { b in
            let m = try await b.createMoment(MomentDraft(title: "Rahul's thing", description: "", visibility: .group))
            link = try await b.share(momentID: m.id, with: [])
        }
        let openedBefore = env.analytics.count(.sharedMomentOpened)
        await env.social.acceptInvite(try XCTUnwrap(link))
        XCTAssertNil(env.social.pendingInviteError)
        let id = try XCTUnwrap(env.social.pendingMomentID)
        XCTAssertTrue(env.social.moments[id]!.memberIDs.contains("me"))
        XCTAssertTrue(env.social.feed.contains { $0.moment.id == id })
        XCTAssertEqual(env.analytics.count(.sharedMomentOpened), openedBefore + 1)
    }

    func testFeedRanksSharedMomentsFirstAndHidesBlocked() async throws {
        let (env, _) = await makeSocial()
        XCTAssertTrue(env.social.feed.count >= 4)
        XCTAssertTrue(env.social.feed.prefix(2).allSatisfy { $0.moment.memberIDs.contains("me") }, env.social.feed.map(\.moment.title).description)
        await env.social.block("u_public")
        XCTAssertFalse(env.social.feed.contains { $0.moment.creatorID == "u_public" })
        await env.social.refreshFeed()
        XCTAssertFalse(env.social.feed.contains { $0.moment.creatorID == "u_public" })
        XCTAssertTrue(env.social.blocked.contains("u_public"))
    }

    func testReactionsCommentsAndModeration() async throws {
        let (env, _) = await makeSocial()
        await env.social.loadMoment("m_goa")
        await env.social.react(momentID: "m_goa", kind: .core)
        XCTAssertEqual(env.social.myReaction(momentID: "m_goa"), .core)
        XCTAssertEqual(env.social.moments["m_goa"]?.reactionCounts["core"], 5)
        await env.social.react(momentID: "m_goa", kind: .core)   // toggle off
        XCTAssertNil(env.social.myReaction(momentID: "m_goa"))
        XCTAssertEqual(env.social.moments["m_goa"]?.reactionCounts["core"], 4)
        let r1 = await env.social.comment(momentID: "m_goa", text: "never again 😂")
        XCTAssertTrue(r1)
        XCTAssertEqual(env.social.comments["m_goa"]?.count, 3)
        let r2 = await env.social.comment(momentID: "m_goa", text: "kys")
        XCTAssertFalse(r2)
        XCTAssertNotNil(env.social.lastError)
    }

    func testNowPostExpiresUnlessSavedToMoment() async throws {
        let (env, backend) = await makeSocial()
        let r3 = await env.social.postNow(text: "chai", photo: nil, place: "Bandra West, Mumbai")
        XCTAssertTrue(r3)
        for _ in 0..<50 where env.social.queue.pendingCount > 0 { try await Task.sleep(for: .milliseconds(50)) }
        let mine = try XCTUnwrap(env.social.nowPosts.first { $0.authorID == "me" })
        XCTAssertEqual(mine.coarsePlace, "Mumbai")
        XCTAssertGreaterThan(mine.expiresAt.timeIntervalSinceNow, 23 * 3600)
        await env.social.saveNow(mine, to: "m_goa")
        for _ in 0..<50 where env.social.queue.pendingCount > 0 { try await Task.sleep(for: .milliseconds(50)) }
        let sides = try await backend.contributions(momentID: "m_goa")
        XCTAssertTrue(sides.contains { $0.caption == "chai" && $0.authorID == "me" })
        XCTAssertEqual(env.social.nowPosts.first { $0.id == mine.id }?.savedToMomentID, "m_goa")
    }

    func testOfflineQueuePersistsAndResumes() async throws {
        let backend = InMemoryBackend(displayName: "R")
        await backend.seedDemo()
        await backend.setOffline(true)
        let dir = FileManager.default.temporaryDirectory.appending(path: "q-\(UUID().uuidString)")
        let media = MediaStore(directory: dir)
        let q1 = UploadQueue(backend: backend, media: media, directory: dir)
        q1.enqueue(.contribution(Contribution(id: "c1", momentID: "m_goa", authorID: "me", authorName: "R", kind: .text, media: nil, caption: "offline note", createdAt: .now, originalTimestamp: nil, reactionCounts: [:], commentCount: 0, uploadState: .pending)))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(q1.pendingCount, 1, "stays queued while offline")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "upload-queue.json").path()))
        // Relaunch: a new queue reads the file and drains once online.
        await backend.setOffline(false)
        let q2 = UploadQueue(backend: backend, media: media, directory: dir)
        XCTAssertEqual(q2.pendingCount, 1)
        q2.drain()
        for _ in 0..<50 where q2.pendingCount > 0 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(q2.pendingCount, 0)
        let sides = try await backend.contributions(momentID: "m_goa")
        XCTAssertTrue(sides.contains { $0.caption == "offline note" })
    }

    func testPermissionErrorsAreNotRetriedForever() async throws {
        let backend = InMemoryBackend(displayName: "R")
        await backend.seedDemo()
        let dir = FileManager.default.temporaryDirectory.appending(path: "q-\(UUID().uuidString)")
        let q = UploadQueue(backend: backend, media: MediaStore(directory: dir), directory: dir)
        // m_run is Dev's public moment; "me" isn't a member but public allows it. m_bday group: me is a member. Use a private moment of someone else:
        _ = try await backend.acting(as: "u_anaya") { b in _ = try await b.createMoment(MomentDraft(title: "private", description: "", visibility: .privateOnly)) }
        let privateID = await backend.moments.values.first { $0.creatorID == "u_anaya" }!.id
        q.enqueue(.contribution(Contribution(id: "c2", momentID: privateID, authorID: "me", authorName: "R", kind: .text, media: nil, caption: "x", createdAt: .now, originalTimestamp: nil, reactionCounts: [:], commentCount: 0, uploadState: .pending)))
        for _ in 0..<30 where q.isDraining { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(q.failedCount, 1)
        XCTAssertFalse(q.isDraining)
    }

    func testSafetySettingsBlockMessagesAndPrivateAccount() async throws {
        let (env, _) = await makeSocial()
        var s = SafetySettings(); s.whoCanMessage = .nobody; s.privateAccount = true
        await env.social.updateSafety(s)
        XCTAssertTrue(env.social.me?.isPrivateAccount ?? false)
        let r4 = await env.social.conversation(with: "u_rahul")
        XCTAssertNotNil(r4, "existing conversation still opens")
        let r5 = await env.social.conversation(with: "u_dev")
        XCTAssertNil(r5, "no new conversations when set to nobody")
    }

    func testWhoCanCommentIsEnforcedForOthers() async throws {
        let (env, backend) = await makeSocial()
        var s = SafetySettings(); s.whoCanComment = .nobody
        await env.social.updateSafety(s)
        // Rahul (a friend) can no longer comment on my Goa Moment; I still can.
        do {
            try await backend.acting(as: "u_rahul") { b in
                _ = try await b.addComment(MomentComment(id: "x", momentID: "m_goa", contributionID: nil, authorID: "u_rahul", authorName: "Rahul", text: "hi", createdAt: .now))
            }
            XCTFail("should be refused")
        } catch { if case SocialError.notAllowed = error {} else { XCTFail("\(error)") } }
        let mine = await env.social.comment(momentID: "m_goa", text: "still me")
        XCTAssertTrue(mine)
    }

    func testMessagesAndMomentReplies() async throws {
        let (env, _) = await makeSocial()
        let convo = await env.social.conversation(with: "u_sarah")
        let c = try XCTUnwrap(convo)
        let r6 = await env.social.send(conversationID: c.id, text: "this one", momentID: "m_goa")
        XCTAssertTrue(r6)
        await env.social.loadMessages(c.id)
        XCTAssertEqual(env.social.messages[c.id]?.last?.momentID, "m_goa")
        XCTAssertEqual(env.social.conversations.first?.id, c.id, "the chat you just wrote in rises to the top")
    }

    func testProfileAndFriendship() async throws {
        let (env, _) = await makeSocial()
        XCTAssertEqual(env.social.moments(with: "u_rahul").count, 3)
        XCTAssertTrue(env.social.isFriend("u_rahul"))
        XCTAssertTrue(env.social.isClose("u_rahul"))
        XCTAssertFalse(env.social.isFriend("u_dev"))
        await env.social.follow("u_dev")
        XCTAssertTrue(env.social.isFriend("u_dev"))
        XCTAssertEqual(env.social.onThisDay.map(\.id), ["m_oldgoa"])
        let r7 = await env.social.updateProfile(displayName: "Rak", handle: "Rak_1", bio: "hi", avatar: nil)
        XCTAssertTrue(r7)
        XCTAssertEqual(env.social.me?.handle, "rak_1")
    }

    func testDeleteAndLeaveRespectOwnership() async throws {
        let (env, _) = await makeSocial()
        let r8 = await env.social.delete(momentID: "m_bday")
        XCTAssertFalse(r8, "not mine")
        let r9 = await env.social.leave(momentID: "m_bday")
        XCTAssertTrue(r9)
        XCTAssertNil(env.social.moments["m_bday"])
        let r10 = await env.social.delete(momentID: "m_goa")
        XCTAssertTrue(r10)
        XCTAssertFalse(env.social.feed.contains { $0.moment.id == "m_goa" })
    }

    func testCollectionsRoundTrip() async throws {
        let (env, backend) = await makeSocial()
        let created = await env.social.createCollection(title: "Goa trips", emoji: "✈️", momentIDs: ["m_goa"])
        let c = try XCTUnwrap(created)
        await env.social.toggle(momentID: "m_oldgoa", in: c.id)
        XCTAssertEqual(env.social.collections.first?.momentIDs, ["m_goa", "m_oldgoa"])
        XCTAssertEqual(env.social.moments(in: env.social.collections[0]).count, 2)
        await env.social.toggle(momentID: "m_goa", in: c.id)
        let persisted = try await backend.collections()
        XCTAssertEqual(persisted.first?.momentIDs, ["m_oldgoa"], "persisted through the backend")
        await env.social.rename(collectionID: c.id, title: "Goa", emoji: "🏖️")
        XCTAssertEqual(env.social.collections[0].title, "Goa")
        await env.social.deleteCollection(c.id)
        XCTAssertTrue(env.social.collections.isEmpty)
        let after = try await backend.collections()
        XCTAssertTrue(after.isEmpty)
    }

    func testSuggestionsAndYearSummaryComeFromRealMoments() async throws {
        let (env, _) = await makeSocial()
        // Dev was at Sarah's 30th with me but I don't follow him; Rahul/Sarah are already followed.
        XCTAssertEqual(env.social.peopleSuggestions.map(\.id), ["u_dev"])
        await env.social.follow("u_dev")
        XCTAssertTrue(env.social.peopleSuggestions.isEmpty)
        let y = try XCTUnwrap(env.social.yearSummary())
        XCTAssertEqual(y.moments, 2, "Goa '26 and Sarah's 30th this year; Goa '25 is last year")
        XCTAssertEqual(y.places, 2)
        XCTAssertEqual(y.topPerson, "Rahul Mehta")
        XCTAssertNil(env.social.yearSummary(2020))
    }

    func testIWasThereJoinsAVisibleMomentButNotAPrivateOne() async throws {
        let (env, backend) = await makeSocial()
        // Dev's public run: I can join.
        let ok = await env.social.join(momentID: "m_run")
        XCTAssertTrue(ok)
        XCTAssertTrue(env.social.moments["m_run"]!.memberIDs.contains("me"))
        // Anaya's private Moment: not visible, not joinable.
        try await backend.acting(as: "u_anaya") { b in _ = try await b.createMoment(MomentDraft(title: "secret", description: "", visibility: .privateOnly)) }
        let secret = await backend.moments.values.first { $0.title == "secret" }!.id
        let denied = await env.social.join(momentID: secret)
        XCTAssertFalse(denied)
    }

    func testMergeDetectsSameDayOverlapAndMovesSides() async throws {
        let (env, _) = await makeSocial()
        let dup = await env.social.createMoment(SocialService.NewMomentInput(title: "Goa again", startAt: env.social.moments["m_goa"]!.startAt, visibility: .group, initialMemberIDs: ["u_rahul"], note: "same trip"))
        let dupID = try XCTUnwrap(dup?.id)
        for _ in 0..<50 where env.social.queue.pendingCount > 0 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(env.social.mergeCandidates(for: "m_goa").map(\.id), [dupID])
        let before = env.social.moments["m_goa"]!.contributionCount
        let merged = await env.social.merge(sourceID: dupID, into: "m_goa")
        XCTAssertTrue(merged)
        XCTAssertNil(env.social.moments[dupID])
        XCTAssertEqual(env.social.moments["m_goa"]?.contributionCount, before + 1)
        XCTAssertTrue(env.social.allContributions("m_goa").contains { $0.caption == "same trip" && $0.authorID == "me" })
    }

    func testAnyoneUpJoinAndMakeItAMoment() async throws {
        let (env, backend) = await makeSocial()
        let posted = await env.social.postNow(text: "Anyone out?", photo: nil, place: "Bandra", activity: .drinks, hours: 3)
        XCTAssertTrue(posted)
        for _ in 0..<50 where env.social.queue.pendingCount > 0 { try await Task.sleep(for: .milliseconds(50)) }
        await env.social.refreshNow()
        let mine = try XCTUnwrap(env.social.nowPosts.first { $0.authorID == "me" && $0.activity == .drinks })
        XCTAssertLessThan(mine.expiresAt.timeIntervalSinceNow, 3.1 * 3600)
        try await backend.acting(as: "u_rahul") { b in _ = try await b.joinNow(id: mine.id) }
        await env.social.refreshNow()
        let joined = try XCTUnwrap(env.social.nowPosts.first { $0.id == mine.id })
        XCTAssertEqual(joined.joinerIDs, ["u_rahul"])
        let made = await env.social.makeMoment(from: joined)
        let m = try XCTUnwrap(made)
        XCTAssertTrue(m.isLive)
        XCTAssertTrue(m.memberIDs.contains("u_rahul"), "everyone who joined is in the Moment")
        XCTAssertEqual(env.social.nowPosts.first { $0.id == mine.id }?.savedToMomentID, m.id)
    }

    func testGroupsHaveChatAndGroupMomentsInviteEveryone() async throws {
        let (env, _) = await makeSocial()
        let rahulUser = await env.social.user("u_rahul"), devUser = await env.social.user("u_dev")
        let rahul = try XCTUnwrap(rahulUser), dev = try XCTUnwrap(devUser)
        let created = await env.social.createGroup(name: "Crew", emoji: "🔥", members: [rahul, dev])
        let g = try XCTUnwrap(created)
        XCTAssertEqual(g.memberIDs, ["me", "u_rahul", "u_dev"])
        XCTAssertNotNil(g.conversationID, "a group gets its own chat")
        XCTAssertTrue(env.social.conversations.contains { $0.id == g.conversationID })
        // Seeded group's Moments: Goa '26 has me + Rahul + Sarah.
        let crew = try XCTUnwrap(env.social.groups.first { $0.id == "g_boys" })
        XCTAssertTrue(env.social.moments(for: crew).contains { $0.id == "m_goa" })
        await env.social.leaveGroup(g.id)
        XCTAssertFalse(env.social.groups.contains { $0.id == g.id })
    }

    func testTimeMachineHighlightsAndPassportUseRealData() async throws {
        let (env, _) = await makeSocial()
        await env.social.loadMoment("m_goa")
        let tm = env.social.timeMachine
        XCTAssertEqual(tm.first?.yearsAgo, 1)
        XCTAssertEqual(tm.first?.moments.map(\.id), ["m_oldgoa"])
        let h = try XCTUnwrap(env.social.highlights(for: "m_goa"))
        XCTAssertEqual(h.mostReacted?.id, "c_m_goa_0", "the seeded first photo carries the reactions")
        XCTAssertEqual(h.addedMost?.count, 2, "Rahul and Sarah tie at two sides each")
        XCTAssertNotNil(h.firstAndLast)
        let p = env.social.passport
        XCTAssertEqual(p.places.first?.name, "Goa")
        XCTAssertGreaterThanOrEqual(p.people, 3)
    }

    func testStartActivityGivesScannableLinkAndOthersJoinUntilFull() async throws {
        let (env, backend) = await makeSocial()
        let started = await env.social.startActivity(title: "", kind: .party, place: "Bandra", openToAnyone: true)
        let m = try XCTUnwrap(started)
        XCTAssertTrue(m.isLive)
        XCTAssertEqual(m.templateID, "activity.party")
        XCTAssertTrue(m.title.hasSuffix("night"), "default title from the activity kind")
        let link = try XCTUnwrap(m.shareURL, "QR needs a link the moment the host screen appears")
        XCTAssertNotNil(MomentQR.make(link.absoluteString))
        // Someone scans: they accept the link and are in.
        try await backend.acting(as: "u_dev") { b in _ = try await b.acceptInvite(url: link) }
        await env.social.loadMoment(m.id)
        XCTAssertTrue(env.social.moments[m.id]!.memberIDs.contains("u_dev"))
        // Free tier caps attendees; the seam for charging later.
        XCTAssertTrue(env.subscriptions.canAdmit(attendees: SubscriptionService.freeEventAttendees - 1))
        XCTAssertFalse(env.subscriptions.canAdmit(attendees: SubscriptionService.freeEventAttendees))
    }

    func testNearbyIsGeoFilteredAndPlacePagesAggregate() async throws {
        let (env, backend) = await makeSocial()
        // Bandra, Mumbai: the seeded Bastian Moment and Rahul's NOW are within 3 km; Goa is not.
        await env.social.refreshNearby(latitude: 19.06, longitude: 72.83)
        XCTAssertTrue(env.social.nearbyMoments.contains { $0.id == "m_bastian" })
        XCTAssertFalse(env.social.nearbyMoments.contains { $0.id == "m_goa" })
        let places = env.social.nearbyPlaces(latitude: 19.06, longitude: 72.83)
        XCTAssertEqual(places.first?.place.name, "Bastian")
        XCTAssertLessThan(places.first!.km, 1)
        // Rahul's NOW is at Bastian but he hasn't allowed discovery → only visible because he follows me.
        XCTAssertTrue(env.social.nearbyNow.contains { $0.id == "n3" })
        // Place page pulls everything at that venue, and a new public Moment lands there.
        let venue = places.first!.place
        var input = SocialService.NewMomentInput(title: "Table 4", visibility: .publicAll)
        input.place = venue
        let created = await env.social.createMoment(input)
        let m = try XCTUnwrap(created)
        await env.social.loadPlace(venue.id)
        XCTAssertTrue(env.social.placeMoments[venue.id]!.contains { $0.id == m.id })
        XCTAssertEqual(m.place?.id, venue.id)
        XCTAssertEqual(m.coarsePlace, "Mumbai", "coarse place is city-level from the venue area")
        // Radius is honoured backend-side too.
        let far = try await backend.nearby(latitude: 15.01, longitude: 74.02, radiusKm: 3)
        XCTAssertEqual(far.map(\.id), [], "Goa Moment is group-visibility, not public")
    }

    func testRegularsAndPlaceClaims() async throws {
        let (env, backend) = await makeSocial()
        await env.social.refreshNearby(latitude: 19.06, longitude: 72.83)
        let venue = env.social.nearbyPlaces(latitude: 19.06, longitude: 72.83).first!.place   // Bastian
        // Two public Moments at the venue with Rahul in both → Rahul is a regular.
        for t in ["Round one", "Round two"] {
            var i = SocialService.NewMomentInput(title: t, visibility: .publicAll, initialMemberIDs: ["u_rahul"]); i.place = venue
            _ = await env.social.createMoment(i)
        }
        await env.social.loadPlace(venue.id)
        XCTAssertTrue(env.social.regulars(at: venue.id).contains { $0.id == "u_rahul" && $0.visits >= 2 })
        XCTAssertEqual(env.social.myVisits(at: venue.id), 3, "two new + Sarah's 30th, which was at the same venue")
        XCTAssertEqual(env.social.myPlaces.first?.place.id, venue.id)
        // Claim: pending until reviewed; a second person can't take it; free plan allows one.
        let claimed = await env.social.claimPlace(venue, businessName: "Bastian", role: "Manager", note: "Window table.")
        XCTAssertTrue(claimed)
        XCTAssertEqual(env.social.claims[venue.id]?.verified, false)
        do {
            try await backend.acting(as: "u_dev") { b in _ = try await b.saveClaim(PlaceClaim(id: venue.id, placeID: venue.id, ownerID: "u_dev", ownerName: "Dev", businessName: "Not mine", role: "Owner", note: "", verified: false, createdAt: .now)) }
            XCTFail("second claimant must be refused")
        } catch { if case SocialError.notAllowed = error {} else { XCTFail("\(error)") } }
        let other = SocialPlace(id: "x", name: "Other", area: "", latitude: 0, longitude: 0, category: nil)
        let second = await env.social.claimPlace(other, businessName: "Two", role: "Owner", note: "")
        XCTAssertFalse(second, "free tier: one place")
    }

    @MainActor func testIdentitySignsMomentsAndBackupRoundTrips() async throws {
        let (env, _) = await makeSocial()
        let id = env.identity.momentID
        XCTAssertTrue(id.hasPrefix("MMT-") && id.count == 18, id)
        XCTAssertEqual(env.social.me?.publicKey, env.identity.publicKeyBase64, "key is published on the profile at start")
        let created = await env.social.createMoment(SocialService.NewMomentInput(title: "Signed night"))
        let m = try XCTUnwrap(created)
        XCTAssertNotNil(m.signature)
        XCTAssertTrue(env.social.isVerified(m))
        var tampered = m; tampered.title = "Edited"
        XCTAssertFalse(env.social.isVerified(tampered), "changing the title breaks the signature")
        // Recovery phrase → encrypted backup → restore gives the same ID; wrong phrase is refused.
        let phrase = IdentityService.generateRecoveryPhrase()
        XCTAssertEqual(phrase.count, 12); XCTAssertTrue(IdentityService.isValidPhrase(phrase))
        let backup = try env.identity.exportBackup(phrase: phrase)
        XCTAssertEqual(try env.identity.importBackup(backup, phrase: phrase), id)
        XCTAssertThrowsError(try env.identity.importBackup(backup, phrase: IdentityService.generateRecoveryPhrase()))
    }

    func testMediaPipelineStripsMetadataAndBounds() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000)).image { ctx in UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000)) }.jpegData(compressionQuality: 1)!
        let p = try XCTUnwrap(MediaPipeline.preparePhoto(big))
        XCTAssertEqual(p.width, 2048)
        XCTAssertEqual(p.height, 1536)
        XCTAssertLessThan(p.data.count, big.count)
        XCTAssertNil(PhotoMetadata.captureDate(from: p.data))
        XCTAssertEqual(SocialService.coarse("Palolem Beach, Canacona, Goa"), "Goa")
    }
}

@MainActor
final class CreatorEconomyTests: XCTestCase {
    private func makeSocial() async -> (AppEnvironment, InMemoryBackend) {
        let backend = InMemoryBackend(displayName: "Rakshit")
        await backend.seedDemo()
        let env = AppEnvironment(storage: try! StorageService(inMemory: true), settings: SettingsStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!), mediaDirectory: FileManager.default.temporaryDirectory.appending(path: "test-media-\(UUID().uuidString)"), backend: backend)
        await env.social.start()
        return (env, backend)
    }

    func testPaidMomentIsLockedUntilSubscribed() async throws {
        let (env, _) = await makeSocial()
        await env.social.loadCreatorPlan("u_public")
        XCTAssertEqual(env.social.plan(for: "u_public")?.tier, .t2)
        XCTAssertFalse(env.social.isSubscribed(to: "u_public"))
        let locked = try XCTUnwrap(env.social.feed.first { $0.moment.id == "m_raw" }?.moment, "paid previews from people you follow are in the feed")
        XCTAssertTrue(locked.isLocked)
        XCTAssertNotNil(locked.coverRef, "the preview keeps its cover so the lock has something to sell")
        await env.social.loadMoment("m_raw")
        XCTAssertTrue(env.social.allContributions("m_raw").isEmpty, "sides never reach a non-subscriber")

        let ok = await env.social.subscribe(to: "u_public")   // test host: no App Store, recorded without a transaction
        XCTAssertTrue(ok)
        XCTAssertTrue(env.social.isSubscribed(to: "u_public"))
        let open = try XCTUnwrap(env.social.feed.first { $0.moment.id == "m_raw" }?.moment)
        XCTAssertFalse(open.isLocked)
        await env.social.loadMoment("m_raw")
        XCTAssertEqual(env.social.allContributions("m_raw").count, 4)
        XCTAssertEqual(env.social.subscription(to: "u_public")?.expiresAt.daysUntil(.now).magnitude ?? 0, 30, accuracy: 1)
    }

    func testTipsReachTheCreatorAndCountTowardEarnings() async throws {
        let (env, backend) = await makeSocial()
        await env.social.loadCreatorPlan("u_sarah")
        let sent = await env.social.tip(creatorID: "u_sarah", momentID: "m_cafe", amount: .large, note: "best ramen")
        XCTAssertTrue(sent)
        let noPlan = await env.social.tip(creatorID: "u_rahul", momentID: nil, amount: .small, note: "")
        XCTAssertFalse(noPlan, "you can only tip someone who has set up a plan (that's where their payout handle lives)")
        var received: [CreatorTip] = []
        try await backend.acting(as: "u_sarah") { b in received = try await b.tips() }
        XCTAssertEqual(received.map(\.note), ["best ramen", "that broth 🙏"])
        let estimate = CreatorEconomics.creatorEstimate([], tips: received, since: .distantPast)
        XCTAssertEqual(estimate, (499 + 99) * 0.7 * 0.8, accuracy: 0.01)
    }

    func testCreatorPlanSubscribersAndEarnings() async throws {
        let (env, backend) = await makeSocial()
        XCTAssertNil(env.social.myPlan)
        let saved = await env.social.savePlan(title: "Behind the lens", pitch: "Every frame.", tier: .t3, perks: ["RAW files", "", "Monthly call"], payoutHint: "rakshit@upi")
        XCTAssertTrue(saved)
        XCTAssertEqual(env.social.myPlan?.perks, ["RAW files", "Monthly call"])
        // Rahul subscribes to me.
        try await backend.acting(as: "u_rahul") { b in _ = try await b.subscribe(to: "me", tier: .t3, transactionID: "txn-1", days: 30) }
        await env.social.refreshCreator()
        XCTAssertEqual(env.social.activeSubscriberCount, 1)
        XCTAssertEqual(env.social.earningsEstimate, 999 * 0.7 * 0.8, accuracy: 0.01)
        // A paid Moment of mine is open to me and to Rahul, locked to Sarah.
        let m = try await backend.createMoment(MomentDraft(title: "RAW set", description: "", visibility: .subscribers))
        var asRahul: SocialMoment?, asSarah: SocialMoment?
        try await backend.acting(as: "u_rahul") { b in asRahul = try await b.moment(id: m.id) }
        XCTAssertEqual(asRahul?.isLocked, false)
        try await backend.acting(as: "u_sarah") { b in asSarah = try await b.moment(id: m.id) }
        XCTAssertEqual(asSarah?.isLocked, true)
        // Stop selling: plan gone, new paid Moments impossible from the UI (visibility hidden), existing subs untouched.
        await env.social.removePlan()
        XCTAssertNil(env.social.myPlan)
        var bought = false
        try? await backend.acting(as: "u_sarah") { b in _ = try await b.subscribe(to: "me", tier: .t3, transactionID: nil, days: 30); bought = true }
        XCTAssertFalse(bought, "nobody can buy a plan that no longer exists")
    }
}

final class MomentMechanicsTests: XCTestCase {
    private func side(_ id: String, _ author: String, at: Date, kind: Contribution.Kind = .photo) -> Contribution {
        Contribution(id: id, momentID: "m", authorID: author, authorName: author, kind: kind, media: kind == .text ? nil : MediaRef(kind: .photo, localRef: "x", remoteID: id), caption: "", createdAt: at, originalTimestamp: at, reactionCounts: [:], commentCount: 0, uploadState: .uploaded)
    }

    func testSameSecondPairsDifferentPeopleOnly() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let sides = [
            side("a1", "alice", at: t), side("b1", "bob", at: t.addingTimeInterval(3)),      // pair, 3s
            side("a2", "alice", at: t.addingTimeInterval(5)),                                // alice again: closer to b1 but b1 already used
            side("a3", "alice", at: t.addingTimeInterval(300)), side("a4", "alice", at: t.addingTimeInterval(302)),   // same person → never a pair
            side("c1", "cara", at: t.addingTimeInterval(600)), side("b2", "bob", at: t.addingTimeInterval(640)),      // 40s apart → outside window
            side("t1", "bob", at: t.addingTimeInterval(3), kind: .text)                     // text never pairs
        ]
        let pairs = TwinFrames.pairs(sides, window: 20)
        XCTAssertEqual(pairs.map { [$0.a.id, $0.b.id] }, [["b1", "a2"]], "closest pair wins; a1 is left out because b1 is taken")
        XCTAssertEqual(pairs.first?.secondsApart, 2)
    }

    func testGapsFindMissingStretchesAndNameWitnesses() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let sides = [side("1", "alice", at: t), side("2", "bob", at: t.addingTimeInterval(20 * 60)), side("3", "cara", at: t.addingTimeInterval(120 * 60)), side("4", "alice", at: t.addingTimeInterval(125 * 60))]
        let gaps = TimelineGaps.find(sides, minGap: 45 * 60)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.minutes, 100)
        XCTAssertEqual(gaps.first?.witnesses, ["bob", "cara"])
        XCTAssertTrue(TimelineGaps.question(for: gaps[0], momentTitle: "Goa '26").contains("Goa '26"))
        XCTAssertTrue(TimelineGaps.find([sides[0]]).isEmpty, "one side is not a timeline")
    }

    func testRitualStreakAndNextDate() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let friday = cal.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 18))!   // a Friday
        func m(_ weeksAgo: Int) -> SocialMoment {
            let d = cal.date(byAdding: .weekOfYear, value: -weeksAgo, to: friday)!
            return SocialMoment(id: "r\(weeksAgo)", creatorID: "c", creatorName: "C", title: "Last light", description: "", coverRef: nil, createdAt: d, startAt: d, endAt: nil, locationName: nil, coarsePlace: nil, visibility: .publicAll, memberIDs: ["c"], memberNames: ["C"], contributionCount: 0, mediaCount: 0, commentCount: 0, reactionCounts: [:], shareCount: 0, isLive: false, templateID: Rituals.templateID, remixedFromID: nil, shareURL: nil, allowsReshare: true, allowsDownload: true, allowsContributions: true)
        }
        let series = [m(0), m(1), m(2), m(4)]   // missed week 3 → streak is 3
        let now = cal.date(byAdding: .day, value: 2, to: friday)!   // the Sunday after
        let s = try! XCTUnwrap(Rituals.summary(of: series[0], in: series + [m(0)].map { var x = $0; x.id = "other"; x.title = "Different"; return x }, now: now, calendar: cal))
        XCTAssertEqual(s.occurrences, 4)
        XCTAssertEqual(s.streak, 3)
        XCTAssertEqual(s.weekday, 6)
        XCTAssertEqual(cal.component(.weekday, from: s.next), 6)
        XCTAssertTrue(s.next > now)
        XCTAssertNil(Rituals.summary(of: { var x = m(0); x.templateID = nil; return x }(), in: [], calendar: cal))
    }
}

@MainActor
final class MessagingTests: XCTestCase {
    func testRepliesReactionsAndGroupChat() async throws {
        let backend = InMemoryBackend(displayName: "Rakshit")
        await backend.seedDemo()
        let env = AppEnvironment(storage: try! StorageService(inMemory: true), settings: SettingsStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!), mediaDirectory: FileManager.default.temporaryDirectory.appending(path: "test-media-\(UUID().uuidString)"), backend: backend)
        await env.social.start()
        let conv = await env.social.conversation(with: "u_sarah")
        let c = try XCTUnwrap(conv)
        await env.social.loadMessages(c.id)
        let target = try XCTUnwrap(env.social.messages[c.id]?.last)
        let sent = await env.social.send(conversationID: c.id, text: "yes!", replyTo: target.id)
        XCTAssertTrue(sent)
        await env.social.react(conversationID: c.id, messageID: target.id, emoji: "🔥")
        let reply = try XCTUnwrap(env.social.messages[c.id]?.first { $0.text == "yes!" })
        XCTAssertEqual(reply.replyToID, target.id); XCTAssertFalse(reply.isReaction)
        XCTAssertEqual(env.social.reactions(on: target).map(\.text), ["🔥"])
        XCTAssertEqual(env.social.conversations.first { $0.id == c.id }?.lastMessage, "yes!", "reactions don't become the preview line")
        // Group chat: one per group, everyone in it.
        let group = try XCTUnwrap(env.social.groups.first { $0.id == "g_boys" })
        let gcOpt = await env.social.groupConversation(group)
        let gc = try XCTUnwrap(gcOpt)
        XCTAssertEqual(Set(gc.participantIDs), Set(group.memberIDs)); XCTAssertEqual(gc.title, "The Goa crew"); XCTAssertTrue(gc.isGroup)
        let againOpt = await env.social.groupConversation(group)
        let again = try XCTUnwrap(againOpt)
        XCTAssertEqual(again.id, gc.id)
        // Unread is local: sending marks it read, a newer message from someone else makes it unread.
        env.social.markRead(gc.id)
        XCTAssertFalse(env.social.isUnread(env.social.conversations.first { $0.id == gc.id }!))
    }
}

final class ReplayExporterTests: XCTestCase {
    func testExportsAVerticalVideoWithTitleBeatsAndEndCard() async throws {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600)).image { ctx in UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 600)) }
        let t = Date()
        let beats = [ReplayExporter.Beat(image: img, note: nil, author: "Rahul", time: t), .init(image: nil, note: "we're waking up at 7", author: "Sarah", time: t.addingTimeInterval(600)), .init(image: img, note: nil, author: "You", time: t.addingTimeInterval(1200))]
        let url = try await ReplayExporter.export(title: "Goa '26", subtitle: "3 people · Goa", beats: beats, inviteLine: "moment://join/abc", options: .init(secondsPerBeat: 1.0, fps: 24, maxSeconds: 60, size: CGSize(width: 540, height: 960)))
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2.2 + 3 * 1.0 + 2.6, accuracy: 0.2)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 540, height: 960))
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0, 10_000)
    }

    func testSixtySecondCapShortensBeatsBeforeDroppingThem() async throws {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).image { ctx in UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300)) }
        let beats = (0..<30).map { ReplayExporter.Beat(image: img, note: nil, author: "P\($0)", time: Date().addingTimeInterval(Double($0) * 60)) }
        let url = try await ReplayExporter.export(title: "Long night", subtitle: "", beats: beats, inviteLine: "x", options: .init(secondsPerBeat: 2.6, fps: 12, maxSeconds: 60, size: CGSize(width: 270, height: 480)))
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertLessThanOrEqual(duration, 60.5)
        XCTAssertGreaterThan(duration, 50, "all 30 sides fit by shortening each beat, not by dropping them")
    }
}

@MainActor
final class ReceiptsAndTypingTests: XCTestCase {
    func testSeenAndTypingShowUpWithNames() async throws {
        let backend = InMemoryBackend(displayName: "Rakshit")
        await backend.seedDemo()
        let env = AppEnvironment(storage: try! StorageService(inMemory: true), settings: SettingsStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!), mediaDirectory: FileManager.default.temporaryDirectory.appending(path: "test-media-\(UUID().uuidString)"), backend: backend)
        await env.social.start()
        let conv = await env.social.conversation(with: "u_sarah")
        let c = try XCTUnwrap(conv)
        await env.social.loadMessages(c.id)
        _ = await env.social.send(conversationID: c.id, text: "see this?")
        XCTAssertTrue(env.social.seenNames(for: c.id).isEmpty, "nobody has seen it yet")
        // Sarah opens the chat.
        try await backend.acting(as: "u_sarah") { b in let last = try await b.messages(conversationID: c.id).last!; try await b.markSeen(conversationID: c.id, lastMessageID: last.id) }
        await env.social.refreshSeen(c.id)
        XCTAssertEqual(env.social.seenNames(for: c.id), ["Sarah Kim"])
        // Typing: the demo backend echoes a burst back from the other person.
        env.social.noteTyping(c.id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(env.social.typingNames(for: c.id), ["Sarah Kim"])
        // A voice note travels as .voice media with a duration.
        let voice = Data(repeating: 1, count: 4000)
        _ = await env.social.send(conversationID: c.id, text: "", voice: voice)
        XCTAssertEqual(env.social.messages[c.id]?.last?.media?.kind, .voice)
        XCTAssertEqual(env.social.conversations.first { $0.id == c.id }?.lastMessage, "Voice note")
    }
}

final class MeetRankerTests: XCTestCase {
    private func profile(_ id: String, _ g: DatingProfile.Gender, _ seeking: [DatingProfile.Gender], year: Int = 1995, hide: Bool = false, overlapOnly: Bool = true) -> DatingProfile {
        DatingProfile(userID: id, displayName: id, birthYear: year, gender: g, seeking: seeking, intent: .dates, prompts: [], photos: [], bio: "", hideFromKnown: hide, overlapOnly: overlapOnly, updatedAt: .now)
    }
    private func moment(_ id: String, members: [String], place: SocialPlace? = nil, daysAgo: Int = 1, ritual: Bool = false, creator: String? = nil, title: String = "M") -> SocialMoment {
        let d = Date().addingTimeInterval(-Double(daysAgo) * 86400)
        return SocialMoment(id: id, creatorID: creator ?? members[0], creatorName: "", title: title, description: "", coverRef: nil, createdAt: d, startAt: d, endAt: nil, locationName: nil, coarsePlace: nil, visibility: .publicAll, memberIDs: members, memberNames: members, contributionCount: 0, mediaCount: 0, commentCount: 0, reactionCounts: [:], shareCount: 0, isLive: false, templateID: ritual ? Rituals.templateID : nil, remixedFromID: nil, shareURL: nil, allowsReshare: true, allowsDownload: true, allowsContributions: true, place: place)
    }

    func testOverlapKindsAndRanking() {
        let cafe = SocialPlace(id: "cafe", name: "Kokoro", area: "", latitude: 19, longitude: 72)
        let me = profile("me", .man, [.woman])
        let a = profile("a", .woman, [.man]), b = profile("b", .woman, [.man]), c = profile("c", .woman, [.man]), d = profile("d", .woman, [.man])
        let moments = [
            moment("m1", members: ["me", "a"]),                                             // shared Moment with a
            moment("m2", members: ["me"], place: cafe), moment("m3", members: ["b"], place: cafe),  // same venue with b
            moment("r1", members: ["host", "me"], ritual: true, creator: "host", title: "Last light"), moment("r2", members: ["host", "c"], daysAgo: 8, ritual: true, creator: "host", title: "Last light")   // same ritual with c
        ]
        let nows = [NowPost(id: "n", authorID: "d", authorName: "D", text: "", media: nil, createdAt: .now, expiresAt: .now.addingTimeInterval(3600), coarsePlace: nil, savedToMomentID: nil, activity: .coffee)]
        let ranked = MeetRanker.rank(me: me, candidates: [a, b, c, d], moments: moments, nows: nows, known: [], passed: [], liked: [], blocked: [])
        XCTAssertEqual(ranked.map(\.id), ["a", "c", "b", "d"], "shared Moment > ritual > venue > out now")
        XCTAssertEqual(ranked[0].overlaps.first?.kind, .sharedMoment)
        XCTAssertEqual(ranked[1].overlaps.first?.label, "You both go to Last light")
        XCTAssertEqual(ranked[3].overlaps.first?.kind, .nearbyNow)
    }

    func testPreferencesPrivacyAndAgeGates() {
        let me = profile("me", .woman, [.man, .nonBinary])
        let wrongWay = profile("x", .man, [.woman], year: 1990)              // fine
        let notSeeking = profile("y", .woman, [.man])                        // I don't seek women
        let notSeekingMe = profile("z", .man, [.man])                        // they don't seek women
        let minor = profile("k", .man, [.woman], year: Calendar.current.component(.year, from: .now) - 17)
        let hidden = profile("h", .man, [.woman], hide: true)
        let stranger = profile("s", .man, [.woman], overlapOnly: false)
        let shared = moment("m", members: ["me", "x", "y", "z", "k", "h"])
        let ranked = MeetRanker.rank(me: me, candidates: [wrongWay, notSeeking, notSeekingMe, minor, hidden, stranger], moments: [shared], nows: [], known: ["h"], passed: [], liked: [], blocked: [])
        XCTAssertEqual(ranked.map(\.id), ["x"], "gender prefs both ways, 18+, hide-from-known and overlap-only all apply")
        var open = me; open.overlapOnly = false
        let ranked2 = MeetRanker.rank(me: open, candidates: [stranger], moments: [], nows: [], known: [], passed: [], liked: [], blocked: [])
        XCTAssertEqual(ranked2.map(\.id), ["s"], "with both sides open to it, no overlap is needed")
    }

    func testMutualLikesMatchDeterministically() {
        let t = Date()
        let sent = [DatingLike(id: "1", fromID: "me", fromName: "Me", toID: "a", note: "", promptQuestion: nil, createdAt: t), DatingLike(id: "2", fromID: "me", fromName: "Me", toID: "b", note: "", promptQuestion: nil, createdAt: t)]
        let received = [DatingLike(id: "3", fromID: "a", fromName: "A", toID: "me", note: "hey", promptQuestion: nil, createdAt: t.addingTimeInterval(10))]
        let m = MeetRanker.matches(me: "me", sent: sent, received: received, names: ["me": "Me", "a": "A"]) { _ in [] }
        XCTAssertEqual(m.map(\.id), ["match_a_me"])
        XCTAssertEqual(m.first?.names, ["A", "Me"])
    }
}

@MainActor
final class MeetFlowTests: XCTestCase {
    func testOptInLikeMatchOpensChatWithTheOverlap() async throws {
        let backend = InMemoryBackend(displayName: "Rakshit")
        await backend.seedDemo()
        let env = AppEnvironment(storage: try! StorageService(inMemory: true), settings: SettingsStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!), mediaDirectory: FileManager.default.temporaryDirectory.appending(path: "test-media-\(UUID().uuidString)"), backend: backend)
        await env.social.start()
        await env.social.refreshMeet()
        XCTAssertNil(env.social.myDating); XCTAssertTrue(env.social.meetCandidates.isEmpty, "nothing until you opt in")
        XCTAssertEqual(env.social.likesReceived.map(\.fromID), ["u_mira"], "likes wait for you even before you opt in")
        for m in env.social.momentsImIn { _ = await env.social.loadMoment(m.id) }
        let photo = try XCTUnwrap(env.social.myPhotosForMeet.first)
        let ok = await env.social.saveDating(DatingProfile(userID: "", displayName: "", birthYear: 1997, gender: .man, seeking: [.woman], intent: .dates, prompts: [.init(question: "My go-to Friday", answer: "Versova.")], photos: [photo], bio: "", hideFromKnown: false, overlapOnly: true, updatedAt: .now))
        XCTAssertTrue(ok)
        // Mira (Friday ritual, likes me) ranks first; Anaya (Marine Drive run with me? no — she's at Marine 6am which I'm not in) may not appear; Dev is a man → filtered.
        let ids = env.social.meetCandidates.map(\.id)
        XCTAssertEqual(ids.first, "u_mira")
        XCTAssertFalse(ids.contains("u_dev"))
        let mira = try XCTUnwrap(env.social.meetCandidates.first)
        XCTAssertTrue(mira.overlaps.contains { $0.kind == .samePlace }, mira.overlaps.map(\.label).description)
        // "Out right now" needs the nearby NOW feed (people you don't follow); load it and re-rank.
        await env.social.refreshNearby(latitude: 19.06, longitude: 72.83)
        await env.social.refreshMeet()
        XCTAssertTrue(env.social.meetCandidates.first?.overlaps.contains { $0.kind == .nearbyNow } == true)
        let match = await env.social.like(mira, note: "The one with the birds.", prompt: "The place I always end up")
        XCTAssertNotNil(match, "she already liked me → match")
        let cid = try XCTUnwrap(match?.conversationID)
        let first = try XCTUnwrap(env.social.messages[cid]?.first)
        XCTAssertTrue(first.text.hasPrefix("It's a match."), first.text)
        XCTAssertFalse(env.social.meetCandidates.contains { $0.id == "u_mira" })
        // Pass hides for good.
        if let next = env.social.meetCandidates.first { await env.social.pass(next); await env.social.refreshMeet(); XCTAssertFalse(env.social.meetCandidates.contains { $0.id == next.id }) }
        await env.social.leaveMeet()
        XCTAssertNil(env.social.myDating)
    }
}

final class ReelBuilderTests: XCTestCase {
    private func side(_ id: String, _ author: String, _ kind: Contribution.Kind, at: Date, media: Bool = true) -> Contribution {
        Contribution(id: id, momentID: "m", authorID: author, authorName: author, kind: kind, media: media ? MediaRef(kind: kind == .video ? .video : .photo, localRef: "l", remoteID: id) : nil, caption: "", createdAt: at, originalTimestamp: at, reactionCounts: [:], commentCount: 0, uploadState: .uploaded)
    }
    private func moment(_ id: String, members: [String] = ["a"], media: Int = 0, live: Bool = false, locked: Bool = false, teaser: Bool = false, daysAgo: Double = 1) -> SocialMoment {
        let d = Date().addingTimeInterval(-daysAgo * 86400)
        var m = SocialMoment(id: id, creatorID: members[0], creatorName: members[0], title: id, description: "", coverRef: nil, createdAt: d, startAt: d, endAt: nil, locationName: nil, coarsePlace: nil, visibility: .publicAll, memberIDs: members, memberNames: members, contributionCount: media, mediaCount: media, commentCount: 0, reactionCounts: [:], shareCount: 0, isLive: live, templateID: nil, remixedFromID: nil, shareURL: nil, allowsReshare: true, allowsDownload: true, allowsContributions: true, isTeaser: teaser)
        m.isLocked = locked
        return m
    }

    func testCutsNeedThreeSidesAndVideosAlwaysBecomeReels() {
        let t = Date()
        let sides: [String: [Contribution]] = [
            "thin": [side("1", "a", .photo, at: t), side("2", "b", .photo, at: t)],                                   // only two → no cut
            "rich": [side("3", "a", .photo, at: t), side("4", "b", .photo, at: t.addingTimeInterval(60)), side("5", "c", .photo, at: t.addingTimeInterval(120))],
            "vid":  [side("6", "a", .video, at: t), side("7", "a", .text, at: t, media: false)]                       // video reel, no cut (one visual)
        ]
        let reels = ReelBuilder.build(moments: [moment("thin", media: 2), moment("rich", members: ["a", "b", "c"], media: 3), moment("vid", media: 1)], sides: { sides[$0] ?? [] }, me: "z")
        XCTAssertEqual(Set(reels.map(\.id)), ["c_rich", "v_6"])
        XCTAssertTrue(reels.first(where: { $0.id == "c_rich" })!.isCut)
        XCTAssertEqual(reels.first(where: { $0.id == "c_rich" })!.sides.count, 3)
        XCTAssertFalse(reels.first(where: { $0.id == "v_6" })!.isCut)
    }

    func testLockedAndUnrevealedTeasersNeverBecomeReels() {
        let t = Date()
        let three = [side("1", "a", .photo, at: t), side("2", "b", .photo, at: t), side("3", "c", .photo, at: t)]
        let reels = ReelBuilder.build(moments: [moment("locked", media: 3, locked: true), moment("teaser", media: 3, teaser: true), moment("mine", members: ["me", "b"], media: 3, teaser: true)], sides: { _ in three }, me: "me")
        XCTAssertEqual(reels.map(\.id), ["c_mine"], "a teaser you're in is fine; one you're not in stays a mystery")
    }

    func testRankingPutsYoursAndLiveFirstAndDemotesSeen() {
        let t = Date()
        let three = [side("1", "a", .photo, at: t), side("2", "b", .photo, at: t), side("3", "c", .photo, at: t)]
        let ms = [moment("old", media: 3, daysAgo: 20), moment("mine", members: ["me", "b", "c"], media: 3, daysAgo: 5), moment("live", media: 3, live: true, daysAgo: 0)]
        let reels = ReelBuilder.build(moments: ms, sides: { _ in three }, me: "me")
        XCTAssertEqual(reels.map(\.id), ["c_live", "c_mine", "c_old"])
        let afterSeen = ReelBuilder.build(moments: ms, sides: { _ in three }, me: "me", seen: ["c_live"])
        XCTAssertEqual(afterSeen.first?.id, "c_mine", "what you've already watched drops down")
    }

    @MainActor func testDemoFeedHasVideoReelsAndCuts() async throws {
        let backend = InMemoryBackend(displayName: "Rakshit")
        await backend.seedDemo()
        let env = AppEnvironment(storage: try! StorageService(inMemory: true), settings: SettingsStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!), mediaDirectory: FileManager.default.temporaryDirectory.appending(path: "test-media-\(UUID().uuidString)"), backend: backend)
        await env.social.start()
        await env.social.refreshReels()
        XCTAssertTrue(env.social.reels.contains { !$0.isCut }, "a real video side is in the feed")
        XCTAssertTrue(env.social.reels.contains { $0.isCut && $0.momentID == "m_goa" })
        let goa = try XCTUnwrap(env.social.reels.first { $0.id == "c_m_goa" })
        XCTAssertGreaterThanOrEqual(Set(goa.sides.map(\.authorID)).count, 2, "a cut is many people's sides")
        XCTAssertEqual(goa.sides, goa.sides.sorted { ($0.originalTimestamp ?? $0.createdAt) < ($1.originalTimestamp ?? $1.createdAt) })
    }
}

final class StorefrontEconomicsTests: XCTestCase {
    func testTakeRatesDifferByRailAndAreNeverConflated() {
        // ₹1000 sold on our own rail: we keep 10%.
        XCTAssertEqual(CreatorEconomics.creatorTake(100_000, rail: .web), 900, accuracy: 0.01)
        // Same price through Apple: Apple takes 30% first, then the app's 80/20 on the rest.
        XCTAssertEqual(CreatorEconomics.creatorTake(100_000, rail: .appStore), 1000 * 0.7 * 0.8, accuracy: 0.01)
        XCTAssertEqual(CreatorEconomics.creatorTake(100_000, rail: .none), 0)
        XCTAssertGreaterThan(CreatorEconomics.creatorTake(100_000, rail: .web), CreatorEconomics.creatorTake(100_000, rail: .appStore))
    }

    func testMonthlyEstimateAddsSalesAndAcceptedBookings() {
        let now = Date(), monthStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now))!
        let sale = VaultPurchase(id: "1", setID: "s", creatorID: "me", buyerID: "b", buyerName: "B", amountMinor: 50_000, currency: "INR", rail: .web, reference: nil, createdAt: now)
        let old = VaultPurchase(id: "2", setID: "s", creatorID: "me", buyerID: "c", buyerName: "C", amountMinor: 50_000, currency: "INR", rail: .web, reference: nil, createdAt: monthStart.addingTimeInterval(-86400))
        func booking(_ status: Booking.Status) -> Booking {
            Booking(id: status.rawValue, offerID: "o", creatorID: "me", creatorName: "Me", buyerID: "b", buyerName: "B", kind: .videoCall, minutes: 15, amountMinor: 100_000, currency: "INR", startsAt: now, status: status, note: "", rail: .web, reference: nil, roomID: "", createdAt: now)
        }
        let total = CreatorEconomics.creatorEstimate([], tips: [], sales: [sale, old], bookings: [booking(.accepted), booking(.requested), booking(.declined)])
        XCTAssertEqual(total, 450 + 900, accuracy: 0.01, "only this month's sales and only accepted/done bookings")
    }
}

@MainActor
final class StorefrontFlowTests: XCTestCase {
    private func env() async throws -> (AppEnvironment, InMemoryBackend) {
        let backend = InMemoryBackend(displayName: "Rakshit")
        await backend.seedDemo()
        let env = AppEnvironment(storage: try StorageService(inMemory: true), settings: SettingsStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!), mediaDirectory: FileManager.default.temporaryDirectory.appending(path: "test-media-\(UUID().uuidString)"), backend: backend)
        await env.social.start()
        return (env, backend)
    }

    func testPaidSetStaysShutUntilBought() async throws {
        let (env, backend) = try await env()
        await env.social.loadStorefront("u_public")
        let sets = env.social.sets(of: "u_public")
        let free = try XCTUnwrap(sets.first { $0.isFree })
        let paid = try XCTUnwrap(sets.first { !$0.isFree })
        XCTAssertTrue(env.social.isUnlocked(free)); XCTAssertFalse(env.social.isUnlocked(paid))
        // Free set opens for anyone; the paid one refuses.
        await env.social.loadItems(free.id)
        XCTAssertEqual(env.social.items(free.id).count, 3)
        var refused = false
        do { _ = try await backend.vaultItems(setID: paid.id) } catch { refused = true }
        XCTAssertTrue(refused, "items are withheld until payment")
        // Buy it: unlocked, and the sale shows on the creator's side with the right take.
        let ok = await env.social.buySet(paid)
        XCTAssertTrue(ok); XCTAssertTrue(env.social.isUnlocked(paid))
        XCTAssertEqual(env.social.items(paid.id).count, 4)
        var sales: [VaultPurchase] = []
        try await backend.acting(as: "u_public") { b in sales = try await b.vaultSales() }
        XCTAssertEqual(sales.map(\.amountMinor), [49900])
        XCTAssertEqual(CreatorEconomics.creatorTake(sales[0].amountMinor, rail: .web), 449.1, accuracy: 0.01)
        // Buying twice doesn't charge twice.
        _ = await env.social.buySet(paid)
        XCTAssertEqual(env.social.myPurchases.filter { $0.setID == paid.id }.count, 1)
    }

    func testPublishASetAndSellTimeWithLinks() async throws {
        let (env, _) = try await env()
        await env.social.refreshStorefront()
        XCTAssertTrue(env.social.mySets.isEmpty)
        let refOpt = await env.social.storeLocalMedia(UIGraphicsImageRenderer(size: .init(width: 40, height: 60)).image { c in UIColor.red.setFill(); c.fill(.init(x: 0, y: 0, width: 40, height: 60)) }.jpegData(compressionQuality: 0.8)!, kind: .photo)
        let ref = try XCTUnwrap(refOpt)
        let savedOpt = await env.social.saveSet(VaultSet(id: "", creatorID: "", creatorName: "", title: "Backstage", blurb: "Ten frames", priceMinor: 29900, currency: "INR", cover: ref, itemCount: 0, isVideo: false, createdAt: .now, visible: true), items: [VaultItem(id: "", setID: "", kind: .photo, media: ref, caption: "", index: 0)])
        let set = try XCTUnwrap(savedOpt)
        XCTAssertEqual(set.creatorID, env.social.myID); XCTAssertEqual(set.itemCount, 1); XCTAssertTrue(set.priceLabel(Locale(identifier: "en_IN")).replacingOccurrences(of: "\u{00a0}", with: "").replacingOccurrences(of: " ", with: "").hasSuffix("299"), set.priceLabel(Locale(identifier: "en_IN")))
        XCTAssertTrue(env.social.isCreator)
        // Time: an offer, then someone books it and I accept.
        let offerOpt = await env.social.saveOffer(BookingOffer(id: "", creatorID: "", creatorName: "", kind: .videoCall, minutes: 20, priceMinor: 199900, currency: "INR", note: "Camera on.", active: true))
        let offer = try XCTUnwrap(offerOpt)
        // Rahul books it; I accept, which mints the room.
        let backend2 = try XCTUnwrap(env.social.backend as? InMemoryBackend)
        var booked: Booking?
        try await backend2.acting(as: "u_rahul") { b in booked = try await b.requestBooking(offerID: offer.id, creatorID: env.social.myID, startsAt: .now.addingTimeInterval(7200), note: "About the sunset shoot", rail: .web, reference: nil) }
        let request = try XCTUnwrap(booked)
        XCTAssertEqual(request.status, .requested); XCTAssertTrue(request.roomID.isEmpty)
        await env.social.refreshStorefront()
        let acceptedOpt = await env.social.setBooking(request.id, .accepted)
        let accepted = try XCTUnwrap(acceptedOpt)
        XCTAssertEqual(accepted.status, .accepted); XCTAssertFalse(accepted.roomID.isEmpty, "a confirmed booking gets a room")
        XCTAssertEqual(env.social.storefrontEarnings, CreatorEconomics.creatorTake(199900, rail: .web), accuracy: 0.01)
        await env.social.saveLinks(CreatorLinks(instagram: "@rakshit", x: "", tiktok: "", youtube: "", website: "rakshit.example"))
        let links = env.social.links(of: env.social.myID).all
        XCTAssertEqual(links.map(\.label), ["Instagram", "Website"])
        XCTAssertEqual(links[0].url.absoluteString, "https://instagram.com/rakshit")
    }
}

final class CreatorFeedTests: XCTestCase {
    private func set(_ id: String, _ creator: String, price: Int, visible: Bool = true, at: Date = .now) -> VaultSet {
        VaultSet(id: id, creatorID: creator, creatorName: creator, title: id, blurb: "", priceMinor: price, currency: "INR", cover: nil, itemCount: 3, isVideo: false, createdAt: at, visible: visible)
    }
    private func paidMoment(_ id: String, _ creator: String, locked: Bool, at: Date = .now) -> SocialMoment {
        var m = SocialMoment(id: id, creatorID: creator, creatorName: creator, title: id, description: "", coverRef: nil, createdAt: at, startAt: at, endAt: nil, locationName: nil, coarsePlace: nil, visibility: .subscribers, memberIDs: [creator], memberNames: [creator], contributionCount: 0, mediaCount: 4, commentCount: 0, reactionCounts: [:], shareCount: 0, isLive: false, templateID: nil, remixedFromID: nil, shareURL: nil, allowsReshare: true, allowsDownload: true, allowsContributions: true)
        m.isLocked = locked
        return m
    }

    func testGatesSayExactlyWhatOpensEachPost() {
        let plan = CreatorPlan(creatorID: "c", creatorName: "C", title: "Inside", pitch: "", tier: .t2, perks: [], payoutHint: "", createdAt: .now)
        let posts = CreatorFeedBuilder.build(
            sets: [set("free", "c", price: 0), set("paid", "c", price: 49900), set("bought", "c", price: 19900), set("mine", "me", price: 9900), set("hidden", "c", price: 100, visible: false)],
            moments: [paidMoment("locked", "c", locked: true), paidMoment("subbed", "d", locked: true)],
            plans: ["c": plan],
            purchases: ["bought"], subscribedTo: ["d"], me: "me")
        func gate(_ id: String) -> CreatorPost.Gate? { posts.first { $0.id == id }?.gate }
        XCTAssertEqual(gate("s_free"), .open)
        XCTAssertEqual(gate("s_bought"), .open, "what you've paid for is open — the feed is also your library")
        XCTAssertEqual(gate("s_mine"), .open)
        XCTAssertEqual(gate("s_paid"), .buy(priceMinor: 49900, currency: "INR"))
        XCTAssertEqual(gate("m_locked"), .subscribe(tier: .t2, title: "Inside"))
        XCTAssertEqual(gate("m_subbed"), .open)
        XCTAssertNil(gate("s_hidden"), "a hidden set isn't in anyone's feed")
        XCTAssertEqual(posts.first { $0.id == "s_paid" }?.priceLabel(Locale(identifier: "en_IN"))?.filter(\.isNumber), "499")
    }

    func testFeedIsNewestFirstAndSkipsBlocked() {
        let old = Date().addingTimeInterval(-86400)
        let posts = CreatorFeedBuilder.build(sets: [set("a", "c", price: 0, at: old), set("b", "c", price: 0), set("x", "blocked", price: 0)], moments: [], plans: [:], purchases: [], subscribedTo: [], me: "me", blocked: ["blocked"])
        XCTAssertEqual(posts.map(\.id), ["s_b", "s_a"])
    }

    @MainActor func testDemoFeedShowsLockedAndFreeSetsFromCreators() async throws {
        let backend = InMemoryBackend(displayName: "Rakshit")
        await backend.seedDemo()
        let env = AppEnvironment(storage: try StorageService(inMemory: true), settings: SettingsStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!), mediaDirectory: FileManager.default.temporaryDirectory.appending(path: "test-media-\(UUID().uuidString)"), backend: backend)
        await env.social.start()
        await env.social.refreshCreatorFeed()
        let feed = env.social.creatorFeed
        XCTAssertTrue(feed.contains { $0.creatorID == "u_public" && !$0.isLocked }, "the free set is open")
        // Both kinds of lock are in the feed: a set you buy, and a Moment the subscription opens.
        let paid = try XCTUnwrap(feed.first { $0.creatorID == "u_public" && $0.setID != nil && $0.isLocked })
        if case .buy(let minor, _) = paid.gate { XCTAssertEqual(minor, 49900) } else { XCTFail("paid set should ask to buy, got \(paid.gate)") }
        let subOnly = try XCTUnwrap(feed.first { $0.momentID != nil && $0.isLocked })
        if case .subscribe(let tier, _) = subOnly.gate { XCTAssertEqual(tier, .t2) } else { XCTFail("subscribers-only Moment should ask to subscribe, got \(subOnly.gate)") }
        // Buying it opens that card without touching anything else.
        await env.social.loadStorefront("u_public")
        let setID = try XCTUnwrap(paid.setID)
        let set = try XCTUnwrap(env.social.sets(of: "u_public").first { $0.id == setID })
        _ = await env.social.buySet(set)
        await env.social.refreshCreatorFeed()
        XCTAssertFalse(try XCTUnwrap(env.social.creatorFeed.first { $0.id == paid.id }).isLocked)
    }
}
