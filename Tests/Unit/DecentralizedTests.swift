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
