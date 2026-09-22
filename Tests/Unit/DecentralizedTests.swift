import XCTest
import CryptoKit
@testable import MOMENT

/// The decentralised layer: signed events, encryption, and two phones agreeing on state without any server.
final class DecentralizedTests: XCTestCase {
    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "mesh-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func testEventSignsAndVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let e = try SignedEvent.make(kind: .profile, key: key, tags: ["a": "1"], content: "{\"x\":1}")
        XCTAssertTrue(e.isValid)
        XCTAssertEqual(e.id.count, 64)
        var tampered = e; tampered.content = "{\"x\":2}"
        XCTAssertFalse(tampered.isValid, "content change must break the signature")
        var retagged = e; retagged.tags["a"] = "2"
        XCTAssertFalse(retagged.isValid, "tags are signed too")
        var forged = e; forged.author = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(forged.isValid)
    }

    func testStoreRejectsInvalidAndDedupes() async throws {
        let store = EventStore(directory: tempDir())
        let key = Curve25519.Signing.PrivateKey()
        let e = try SignedEvent.make(kind: .now, key: key, content: "{}")
        let first = await store.ingest(e)
        let again = await store.ingest(e)
        XCTAssertTrue(first); XCTAssertFalse(again)
        var bad = e; bad.sig = Data(repeating: 1, count: 64).base64EncodedString()
        let rejected = await store.ingest(bad)
        XCTAssertFalse(rejected)
        let count = await store.count
        XCTAssertEqual(count, 1)
    }

    func testStorePersistsAcrossReload() async throws {
        let dir = tempDir()
        let key = Curve25519.Signing.PrivateKey()
        do { let s = EventStore(directory: dir); await s.ingest(try SignedEvent.make(kind: .follow, key: key, tags: ["to": "x"], content: "{}")) }
        let s2 = EventStore(directory: dir)
        let follows = await s2.all(.follow)
        XCTAssertEqual(follows.count, 1)
    }

    func testDeleteOnlyByAuthor() async throws {
        let store = EventStore(directory: tempDir())
        let alice = Curve25519.Signing.PrivateKey(), mallory = Curve25519.Signing.PrivateKey()
        let post = try SignedEvent.make(kind: .now, key: alice, content: "{}")
        await store.ingest(post)
        await store.ingest(try SignedEvent.make(kind: .delete, key: mallory, tags: ["target": post.id], content: "{}"))
        var visible = await store.all(.now)
        XCTAssertEqual(visible.count, 1, "someone else's delete is ignored")
        await store.ingest(try SignedEvent.make(kind: .delete, key: alice, tags: ["target": post.id], content: "{}"))
        visible = await store.all(.now)
        XCTAssertEqual(visible.count, 0)
    }

    func testPrivateMomentUnreadableWithoutKey() async throws {
        let dir = tempDir()
        let alice = DecentralizedBackend(key: Curve25519.Signing.PrivateKey(), media: MediaStore(directory: dir.appending(path: "m")), store: EventStore(directory: dir.appending(path: "a")), keys: MomentKeys(namespace: "test.a.\(UUID().uuidString)"))
        _ = try await alice.updateProfile(displayName: "Alice", handle: "alice", bio: "", avatar: nil)
        let m = try await alice.createMoment(MomentDraft(title: "Secret dinner", description: "", visibility: .group))
        let root = await alice.store.get([m.id]).first!
        XCTAssertEqual(root.tags["enc"], "1")
        XCTAssertFalse(root.content.contains("Secret"), "relays and strangers see ciphertext only")
        // Bob receives the raw event but has no key.
        let bobStore = EventStore(directory: dir.appending(path: "b"))
        let bob = DecentralizedBackend(key: Curve25519.Signing.PrivateKey(), media: MediaStore(directory: dir.appending(path: "m2")), store: bobStore, keys: MomentKeys(namespace: "test.b.\(UUID().uuidString)"))
        await bobStore.ingest(root)
        do { _ = try await bob.moment(id: m.id); XCTFail("must not be readable") } catch {}
        // With the invite link (carrying the key) he can join and read it.
        let url = m.shareURL!
        XCTAssertNotNil(url.fragment, "invite carries the Moment key in the fragment")
        let isInvite = await SocialService.isInviteURL(url)
        XCTAssertTrue(isInvite)
        let joined = try await bob.acceptInvite(url: url)
        XCTAssertEqual(joined.title, "Secret dinner")
        let bobID = await bob.myID
        XCTAssertTrue(joined.memberIDs.contains(bobID))
    }

    func testTwoPhonesConvergeOnPublicMoment() async throws {
        let dir = tempDir()
        let aStore = EventStore(directory: dir.appending(path: "a")), bStore = EventStore(directory: dir.appending(path: "b"))
        let alice = DecentralizedBackend(key: Curve25519.Signing.PrivateKey(), media: MediaStore(directory: dir.appending(path: "ma")), store: aStore)
        let bob = DecentralizedBackend(key: Curve25519.Signing.PrivateKey(), media: MediaStore(directory: dir.appending(path: "mb")), store: bStore)
        _ = try await alice.updateProfile(displayName: "Alice", handle: "alice", bio: "", avatar: nil)
        _ = try await bob.updateProfile(displayName: "Bob", handle: "bob", bio: "", avatar: nil)
        let place = SocialPlace(id: SocialPlace.makeID(name: "Café", latitude: 19.06, longitude: 72.83), name: "Café", area: "Bandra", latitude: 19.06, longitude: 72.83, category: "cafe")
        let m = try await alice.createMoment(MomentDraft(title: "Sunset", description: "", visibility: .publicAll, place: place))
        // "Sync": copy every event Alice has to Bob (what mesh/relay does over the wire).
        for e in await aStore.get(Array(await aStore.ids())) { await bStore.ingest(e) }
        let seen = try await bob.moment(id: m.id)
        XCTAssertEqual(seen.creatorName, "Alice")
        let near = try await bob.nearby(latitude: 19.061, longitude: 72.831, radiusKm: 2)
        XCTAssertEqual(near.map(\.id), [m.id])
        // Bob adds a side; Alice sees it after sync.
        _ = try await bob.join(momentID: m.id)
        _ = try await bob.addContribution(Contribution(id: "", momentID: m.id, authorID: "", authorName: "Bob", kind: .text, media: nil, caption: "was there", createdAt: .now, originalTimestamp: nil, reactionCounts: [:], commentCount: 0, uploadState: .pending), mediaData: nil)
        try await Task.sleep(for: .milliseconds(50))
        for e in await bStore.get(Array(await bStore.ids())) { await aStore.ingest(e) }
        let sides = try await alice.contributions(momentID: m.id)
        XCTAssertEqual(sides.map(\.caption), ["was there"])
        let updated = try await alice.moment(id: m.id)
        XCTAssertEqual(updated.memberIDs.count, 2)
        let bobID = await bob.myID
        let bobUser = try await alice.user(id: bobID)
        XCTAssertEqual(bobUser.handle, "bob")
    }

    func testGeoCells() {
        XCTAssertEqual(GeoCell.cell(lat: 19.07, lon: 72.87), "190_728")
        let cells = GeoCell.cells(lat: 19.07, lon: 72.87, radiusKm: 5)
        XCTAssertTrue(cells.contains("190_728"))
        XCTAssertTrue(cells.count >= 1 && cells.count <= 9)
    }
}

/// Paid content over the mesh: the creator's phone hands the key to whoever paid, sealed to their agreement key.
final class DecentralizedCreatorTests: XCTestCase {
    func testSubscriberGetsKeyViaGrantAndOthersStayLocked() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mesh-creator-\(UUID().uuidString)")
        func phone(_ n: String) -> (DecentralizedBackend, EventStore) {
            let store = EventStore(directory: dir.appending(path: n))
            return (DecentralizedBackend(key: Curve25519.Signing.PrivateKey(), agreement: Curve25519.KeyAgreement.PrivateKey(), media: MediaStore(directory: dir.appending(path: "m-\(n)")), store: store, keys: MomentKeys(namespace: "test.\(n).\(UUID().uuidString)")), store)
        }
        let (alice, aStore) = phone("alice"), (bob, bStore) = phone("bob"), (eve, eStore) = phone("eve")
        _ = try await alice.updateProfile(displayName: "Alice", handle: "alice", bio: "", avatar: nil)
        _ = try await bob.updateProfile(displayName: "Bob", handle: "bob", bio: "", avatar: nil)
        _ = try await eve.updateProfile(displayName: "Eve", handle: "eve", bio: "", avatar: nil)
        func sync(_ from: EventStore, _ to: EventStore) async { for e in await from.get(Array(await from.ids())) { await to.ingest(e) } }

        // Alice sells; makes a paid Moment.
        _ = try await alice.saveCreatorPlan(CreatorPlan(creatorID: "", creatorName: "", title: "Raw frames", pitch: "All of them", priceMinor: 49900, currency: "INR", perks: [], payoutHint: "alice@upi", createdAt: .now))
        let m = try await alice.createMoment(MomentDraft(title: "Friday raw", description: "the whole set", visibility: .subscribers))
        let root = await aStore.get([m.id]).first!
        let aliceID = await alice.myID, bobID = await bob.myID
        XCTAssertEqual(root.tags["sub"], aliceID)
        XCTAssertFalse(root.content.contains("the whole set"), "full payload is sealed; only the preview is readable")
        XCTAssertTrue(root.content.contains("Friday raw"), "preview title is public so the lock can sell")

        // Everyone receives everything; nobody but Alice can open it yet.
        await sync(aStore, bStore); await sync(aStore, eStore); await sync(bStore, aStore); await sync(eStore, aStore)
        let bobLocked = try await bob.moment(id: m.id)
        XCTAssertTrue(bobLocked.isLocked); XCTAssertEqual(bobLocked.title, "Friday raw"); XCTAssertEqual(bobLocked.description, "")

        // Bob pays (test: no transaction). His subscribe event reaches Alice, whose phone grants him the key.
        _ = try await bob.subscribe(to: aliceID, tier: .t2, transactionID: "txn-bob", days: 30)
        await sync(bStore, aStore)
        let subs = try await alice.subscribers()          // grants pending subscribers
        XCTAssertEqual(subs.map(\.subscriberName), ["Bob"])
        let grants = await aStore.all(.grant)
        XCTAssertEqual(grants.count, 1)
        XCTAssertEqual(grants.first?.tags["to"], bobID)

        await sync(aStore, bStore); await sync(aStore, eStore)
        await bob.processGrants()
        await eve.processGrants()
        let bobOpen = try await bob.moment(id: m.id)
        XCTAssertFalse(bobOpen.isLocked); XCTAssertEqual(bobOpen.description, "the whole set")
        let eveStill = try await eve.moment(id: m.id)
        XCTAssertTrue(eveStill.isLocked, "Eve holds the same bytes as Bob, including his grant, and can't open any of it")

        // Alice adds a side; Bob reads it, Eve can't.
        _ = try await alice.addContribution(Contribution(id: "", momentID: m.id, authorID: "", authorName: "Alice", kind: .text, media: nil, caption: "frame 1", createdAt: .now, originalTimestamp: nil, reactionCounts: [:], commentCount: 0, uploadState: .pending), mediaData: nil)
        try await Task.sleep(for: .milliseconds(50))
        await sync(aStore, bStore); await sync(aStore, eStore)
        let bobSides = try await bob.contributions(momentID: m.id)
        XCTAssertEqual(bobSides.map(\.caption), ["frame 1"])
        do { _ = try await eve.contributions(momentID: m.id); XCTFail("locked") } catch {}
    }
}

final class DecentralizedMessagingTests: XCTestCase {
    func testEncryptedChatWithPhotoReplyAndGroup() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mesh-chat-\(UUID().uuidString)")
        func phone(_ n: String) -> (DecentralizedBackend, EventStore) {
            let store = EventStore(directory: dir.appending(path: n))
            return (DecentralizedBackend(key: Curve25519.Signing.PrivateKey(), media: MediaStore(directory: dir.appending(path: "m-\(n)")), store: store, keys: MomentKeys(namespace: "test.\(n).\(UUID().uuidString)")), store)
        }
        let (alice, aStore) = phone("a"), (bob, bStore) = phone("b"), (eve, eStore) = phone("e")
        _ = try await alice.updateProfile(displayName: "Alice", handle: "alice", bio: "", avatar: nil)
        _ = try await bob.updateProfile(displayName: "Bob", handle: "bob", bio: "", avatar: nil)
        func sync(_ from: EventStore, _ to: EventStore) async { for e in await from.get(Array(await from.ids())) { await to.ingest(e) } }
        await sync(bStore, aStore)
        let bobID = await bob.myID
        let c = try await alice.conversation(with: bobID)
        let url = try await alice.share(momentID: c.id, with: [bobID])   // the chat's key travels in the invite, never through a relay
        await sync(aStore, bStore); await sync(aStore, eStore)
        _ = try await bob.acceptInvite(url: url)
        let photo = Data(repeating: 7, count: 2048)
        _ = try await alice.send(DirectMessage(id: "", conversationID: c.id, authorID: "", authorName: "Alice", text: "look", media: nil, momentID: nil, createdAt: .now), mediaData: photo)
        await sync(aStore, bStore); await sync(aStore, eStore)
        let seen = try await bob.messages(conversationID: c.id)
        XCTAssertEqual(seen.map(\.text), ["look"]); XCTAssertNotNil(seen.first?.media, "photo arrives inside the sealed message")
        _ = try await bob.send(DirectMessage(id: "", conversationID: c.id, authorID: "", authorName: "Bob", text: "🔥", media: nil, momentID: nil, createdAt: .now, replyToID: seen[0].id), mediaData: nil)
        await sync(bStore, aStore); await sync(bStore, eStore)
        let back = try await alice.messages(conversationID: c.id)
        XCTAssertEqual(back.last?.replyToID, seen[0].id); XCTAssertEqual(back.last?.isReaction, true)
        // Eve has every byte and reads nothing.
        let eveView = try? await eve.messages(conversationID: c.id)
        XCTAssertTrue((eveView ?? []).isEmpty)
        let raw = await eStore.forMoment(c.id).filter { $0.kind == .comment }
        XCTAssertEqual(raw.count, 2); XCTAssertFalse(raw[0].content.contains("look"))
        let convs = try await bob.conversations()
        XCTAssertEqual(convs.first?.lastMessage, "look", "a reaction is not the preview")
    }
}

final class DecentralizedReceiptsTests: XCTestCase {
    func testSeenIsAnEventAndTypingIsNeverStored() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mesh-seen-\(UUID().uuidString)")
        let aStore = EventStore(directory: dir.appending(path: "a")), bStore = EventStore(directory: dir.appending(path: "b"))
        let alice = DecentralizedBackend(key: Curve25519.Signing.PrivateKey(), media: MediaStore(directory: dir.appending(path: "ma")), store: aStore, keys: MomentKeys(namespace: "t.a.\(UUID().uuidString)"))
        let bob = DecentralizedBackend(key: Curve25519.Signing.PrivateKey(), media: MediaStore(directory: dir.appending(path: "mb")), store: bStore, keys: MomentKeys(namespace: "t.b.\(UUID().uuidString)"))
        _ = try await alice.updateProfile(displayName: "Alice", handle: "alice", bio: "", avatar: nil)
        _ = try await bob.updateProfile(displayName: "Bob", handle: "bob", bio: "", avatar: nil)
        func sync(_ from: EventStore, _ to: EventStore) async { for e in await from.get(Array(await from.ids())) { await to.ingest(e) } }
        await sync(bStore, aStore)
        let bobID = await bob.myID, aliceID = await alice.myID
        let c = try await alice.conversation(with: bobID)
        let url = try await alice.share(momentID: c.id, with: [bobID])
        await sync(aStore, bStore); _ = try await bob.acceptInvite(url: url)
        let m = try await alice.send(DirectMessage(id: "", conversationID: c.id, authorID: "", authorName: "Alice", text: "hi", media: nil, momentID: nil, createdAt: .now), mediaData: nil)
        await sync(aStore, bStore)
        try await bob.markSeen(conversationID: c.id, lastMessageID: m.id)
        try await bob.markSeen(conversationID: c.id, lastMessageID: m.id)   // idempotent: one event
        await sync(bStore, aStore)
        let seen = try await alice.seen(conversationID: c.id)
        XCTAssertEqual(seen[bobID], m.id)
        let seenEvents = await aStore.all(.seen)
        XCTAssertEqual(seenEvents.count, 1)
        // Typing goes through transports as a whisper; with no transport attached nothing is written anywhere.
        let before = await bStore.count
        await bob.setTyping(conversationID: c.id, typing: true)
        let after = await bStore.count
        XCTAssertEqual(before, after, "typing never touches the store")
        XCTAssertNotEqual(aliceID, bobID)
    }
}

final class DecentralizedMeetTests: XCTestCase {
    func testLikesAreSealedToTheRecipient() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mesh-meet-\(UUID().uuidString)")
        func phone(_ n: String) -> (DecentralizedBackend, EventStore) {
            let store = EventStore(directory: dir.appending(path: n))
            return (DecentralizedBackend(key: Curve25519.Signing.PrivateKey(), agreement: Curve25519.KeyAgreement.PrivateKey(), media: MediaStore(directory: dir.appending(path: "m-\(n)")), store: store, keys: MomentKeys(namespace: "t.\(n).\(UUID().uuidString)")), store)
        }
        let (alice, aStore) = phone("a"), (bob, bStore) = phone("b"), (eve, eStore) = phone("e")
        for (p, n) in [(alice, "Alice"), (bob, "Bob"), (eve, "Eve")] { _ = try await p.updateProfile(displayName: n, handle: n.lowercased(), bio: "", avatar: nil) }
        func sync(_ from: EventStore, _ to: EventStore) async { for e in await from.get(Array(await from.ids())) { await to.ingest(e) } }
        await sync(aStore, bStore); await sync(bStore, aStore); await sync(aStore, eStore); await sync(bStore, eStore)
        let bobID = await bob.myID
        _ = try await bob.saveDatingProfile(DatingProfile(userID: "", displayName: "", birthYear: 1996, gender: .man, seeking: [.woman], intent: .dates, prompts: [.init(question: "q", answer: "a")], photos: [], bio: "", hideFromKnown: false, overlapOnly: false, updatedAt: .now))
        await sync(bStore, aStore)
        let candidates = try await alice.datingCandidates()
        XCTAssertEqual(candidates.map(\.userID), [bobID])
        _ = try await alice.like(userID: bobID, note: "coffee?", promptQuestion: "q")
        await sync(aStore, bStore); await sync(aStore, eStore)
        let received = try await bob.likesReceived()
        XCTAssertEqual(received.map(\.note), ["coffee?"]); XCTAssertEqual(received.first?.fromName, "Alice")
        let eveSees = try await eve.likesReceived()
        XCTAssertTrue(eveSees.isEmpty)
        let raw = await eStore.all(.like)
        XCTAssertEqual(raw.count, 1); XCTAssertFalse(raw[0].content.contains("coffee"), "the note is sealed; Eve holds ciphertext")
        // Withdrawing the profile removes Bob from everyone's stack.
        try await bob.removeDatingProfile()
        await sync(bStore, aStore)
        let after = try await alice.datingCandidates()
        XCTAssertTrue(after.isEmpty)
    }
}

final class DecentralizedStorefrontTests: XCTestCase {
    func testPaidSetIsCiphertextUntilTheCreatorHandsOverTheKey() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mesh-shop-\(UUID().uuidString)")
        func phone(_ n: String) -> (DecentralizedBackend, EventStore, MediaStore) {
            let store = EventStore(directory: dir.appending(path: n)), media = MediaStore(directory: dir.appending(path: "m-\(n)"))
            return (DecentralizedBackend(key: Curve25519.Signing.PrivateKey(), agreement: Curve25519.KeyAgreement.PrivateKey(), media: media, store: store, keys: MomentKeys(namespace: "t.\(n).\(UUID().uuidString)")), store, media)
        }
        let (creator, cStore, cMedia) = phone("c"), (buyer, bStore, _) = phone("b"), (eve, eStore, _) = phone("e")
        for (p, n) in [(creator, "Creator"), (buyer, "Buyer"), (eve, "Eve")] { _ = try await p.updateProfile(displayName: n, handle: n.lowercased(), bio: "", avatar: nil) }
        func sync(_ from: EventStore, _ to: EventStore) async { for e in await from.get(Array(await from.ids())) { await to.ingest(e) } }
        await sync(bStore, cStore); await sync(eStore, cStore); await sync(cStore, bStore); await sync(cStore, eStore)

        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 90)).image { c in UIColor.magenta.setFill(); c.fill(CGRect(x: 0, y: 0, width: 60, height: 90)) }.jpegData(compressionQuality: 0.9)!
        let local = try await cMedia.store(jpeg, extension: "jpg")
        let ref = MediaRef(kind: .photo, localRef: local, remoteID: nil)
        let set = try await creator.saveVaultSet(VaultSet(id: "", creatorID: "", creatorName: "", title: "Backstage", blurb: "Ten frames", priceMinor: 49900, currency: "INR", cover: ref, itemCount: 0, isVideo: false, createdAt: .now, visible: true), items: [VaultItem(id: "", setID: "", kind: .photo, media: ref, caption: "one", index: 0)], media: [:])
        await sync(cStore, bStore); await sync(cStore, eStore)

        // Metadata is public: everyone sees the title and the price, nobody sees the photos.
        let seen = try await buyer.vaultSets(creatorID: await creator.myID)
        XCTAssertEqual(seen.map(\.title), ["Backstage"]); XCTAssertEqual(seen.first?.priceMinor, 49900)
        var refused = false
        do { _ = try await buyer.vaultItems(setID: set.id) } catch { refused = true }
        XCTAssertTrue(refused)
        let rawEvents = await eStore.all(.vaultSet)
        let raw = try XCTUnwrap(rawEvents.last)
        XCTAssertTrue(raw.content.contains("Backstage"), "the shop window is public")
        XCTAssertFalse(raw.content.contains("\"caption\":\"one\""), "the goods are sealed")

        // Buyer pays; the creator's phone releases the key sealed to them.
        _ = try await buyer.buyVaultSet(id: set.id, rail: .web, reference: "ch_test_123")
        await sync(bStore, cStore)
        let sales = try await creator.vaultSales()
        XCTAssertEqual(sales.map(\.amountMinor), [49900]); XCTAssertEqual(sales.first?.rail, .web)
        await sync(cStore, bStore); await sync(cStore, eStore)
        await buyer.processGrants(); await eve.processGrants()
        let items = try await buyer.vaultItems(setID: set.id)
        XCTAssertEqual(items.map(\.caption), ["one"]); XCTAssertNotNil(items.first?.media)
        var eveRefused = false
        do { _ = try await eve.vaultItems(setID: set.id) } catch { eveRefused = true }
        XCTAssertTrue(eveRefused, "Eve holds every byte, including the key handoff, and still can't open it")

        // Withdrawing rotates the key: whoever already paid keeps what they have, nothing new leaks.
        try await creator.deleteVaultSet(id: set.id)
        await sync(cStore, bStore)
        let gone = try await buyer.vaultSets(creatorID: await creator.myID)
        XCTAssertTrue(gone.isEmpty)
    }

    func testBookingsOnlyMoveWhenTheRightPersonMovesThem() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mesh-book-\(UUID().uuidString)")
        func phone(_ n: String) -> (DecentralizedBackend, EventStore) {
            let store = EventStore(directory: dir.appending(path: n))
            return (DecentralizedBackend(key: Curve25519.Signing.PrivateKey(), agreement: Curve25519.KeyAgreement.PrivateKey(), media: MediaStore(directory: dir.appending(path: "m-\(n)")), store: store, keys: MomentKeys(namespace: "t.\(n).\(UUID().uuidString)")), store)
        }
        let (creator, cStore) = phone("c"), (fan, fStore) = phone("f")
        _ = try await creator.updateProfile(displayName: "Creator", handle: "c", bio: "", avatar: nil)
        _ = try await fan.updateProfile(displayName: "Fan", handle: "f", bio: "", avatar: nil)
        func sync(_ from: EventStore, _ to: EventStore) async { for e in await from.get(Array(await from.ids())) { await to.ingest(e) } }
        let offer = try await creator.saveBookingOffer(BookingOffer(id: "", creatorID: "", creatorName: "", kind: .videoCall, minutes: 15, priceMinor: 99900, currency: "INR", note: "Camera on.", active: true))
        await sync(cStore, fStore)
        let creatorID = await creator.myID
        let b = try await fan.requestBooking(offerID: offer.id, creatorID: creatorID, kind: .videoCall, startsAt: .now.addingTimeInterval(3600), note: "hi", rail: .web, reference: nil)
        await sync(fStore, cStore)
        // The fan can't accept their own booking.
        var blocked = false
        do { _ = try await fan.setBookingStatus(id: b.id, status: .accepted) } catch { blocked = true }
        XCTAssertTrue(blocked)
        let accepted = try await creator.setBookingStatus(id: b.id, status: .accepted)
        XCTAssertEqual(accepted.status, .accepted); XCTAssertFalse(accepted.roomID.isEmpty)
        await sync(cStore, fStore)
        let fanView: [Booking] = try await fan.myBookings()
        XCTAssertEqual(fanView.first?.status, Booking.Status.accepted)
        XCTAssertEqual(fanView.first?.roomID, accepted.roomID, "both sides land on the same room")
    }
}
