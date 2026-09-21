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
        _ = try await alice.saveCreatorPlan(CreatorPlan(creatorID: "", creatorName: "", title: "Raw frames", pitch: "All of them", tier: .t2, perks: [], payoutHint: "alice@upi", createdAt: .now))
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
