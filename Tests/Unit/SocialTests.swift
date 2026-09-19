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
        XCTAssertEqual(env.social.messages[c.id]?.first?.momentID, "m_goa")
        XCTAssertEqual(env.social.conversations.first?.id, c.id)
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
