import Foundation
import CryptoKit

/// Fully decentralised backend: no MOMENT servers, no Apple database. State is derived from the
/// signed events this device has seen; new actions are signed events fanned out to peers (mesh)
/// and relays (open WebSocket servers anyone can run). Invite-only Moments are encrypted with a
/// per-Moment key that only travels inside the invite link/QR.
///
/// Identity = the device's Curve25519 key (`IdentityService`). User id = public key (base64).
actor DecentralizedBackend: SocialBackend {
    nonisolated let name = "mesh"
    let store: EventStore
    private let key: Curve25519.Signing.PrivateKey
    private let agreement: Curve25519.KeyAgreement.PrivateKey
    private let media: MediaStore
    let keys: MomentKeys
    private var transports: [EventTransport] = []
    private var profileCache: [String: SocialUser] = [:]
    private var localBlocked: Set<String> = []
    private var localMuted: Set<String> = []
    private var safety = SafetySettings()
    private var status: AccountStatus = .available

    struct Payloads {
        struct Profile: Codable { var displayName: String; var handle: String; var bio: String; var avatar: String?; var privateAccount: Bool; var momentID: String; var agreePK: String? }
        /// Subscribers-only Moment: a readable preview for everyone, the real thing sealed under the creator key.
        struct Locked: Codable { var preview: Moment; var sealed: String }
        struct Plan: Codable { var title: String; var pitch: String; var tier: String; var perks: [String]; var payoutHint: String; var creatorName: String; var priceMinor: Int? = nil; var currency: String? = nil }
        struct Subscribe: Codable { var tier: String; var days: Int; var transactionID: String?; var name: String }
        struct Tip: Codable { var amount: String; var note: String; var transactionID: String?; var name: String }
        struct Dating: Codable { var profile: DatingProfile?; var photos: [String] }   // photos as base64 thumbnails; nil profile = withdrawn
        struct Like: Codable { var note: String; var prompt: String?; var name: String }
        /// The set as everyone sees it: title, price, cover. The items are sealed under the set key.
        struct Vault: Codable { var set: VaultSet?; var cover: String?; var sealedItems: String?; var itemCount: Int }
        struct Buy: Codable { var amountMinor: Int; var currency: String; var rail: String; var reference: String?; var name: String }
        struct Offer: Codable { var offer: BookingOffer? }
        struct BookingBody: Codable { var booking: Booking }
        struct Links: Codable { var links: CreatorLinks }
        struct Moment: Codable { var title: String; var description: String; var startAt: Date?; var endAt: Date?; var locationName: String?; var coarsePlace: String?; var visibility: String; var templateID: String?; var remixedFromID: String?; var isLive: Bool; var cover: String?; var isTeaser: Bool; var place: SocialPlace?; var creatorName: String }
        struct Update: Codable { var title: String?; var description: String?; var visibility: String?; var isLive: Bool?; var allowsContributions: Bool?; var isTeaser: Bool?; var cover: String? }
        struct Side: Codable { var kind: String; var caption: String; var media: String?; var mediaKind: String?; var originalTimestamp: Date?; var authorName: String; var w: Int?; var h: Int? }
        struct Comment: Codable { var text: String; var contributionID: String?; var authorName: String; var media: String? = nil; var replyTo: String? = nil; var mediaKind: String? = nil; var duration: Double? = nil }
        struct Reaction: Codable { var kind: String?; var contributionID: String? }
        struct Now: Codable { var text: String; var media: String?; var expiresAt: Date; var coarsePlace: String?; var activity: String; var place: SocialPlace?; var authorName: String }
        struct Join: Codable { var name: String }
        struct Group: Codable { var name: String; var emoji: String; var memberIDs: [String]; var memberNames: [String]; var ownerID: String }
        struct Claim: Codable { var businessName: String; var role: String; var note: String; var ownerName: String }
        struct Report: Codable { var targetUserID: String?; var targetMomentID: String?; var reason: String; var details: String }
    }

    init(key: Curve25519.Signing.PrivateKey, agreement: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey(), media: MediaStore, store: EventStore? = nil, keys: MomentKeys = MomentKeys()) {
        self.key = key; self.agreement = agreement; self.media = media; self.keys = keys
        self.store = store ?? EventStore()
        if let raw = Keychain.get("mesh.safety"), let s = try? JSONDecoder().decode(SafetySettings.self, from: raw) { safety = s }
        localBlocked = Set(UserDefaults.standard.stringArray(forKey: "mesh.blocked") ?? [])
        localMuted = Set(UserDefaults.standard.stringArray(forKey: "mesh.muted") ?? [])
    }

    var myID: String { key.publicKey.rawRepresentation.base64EncodedString() }

    /// Wires the production transports: local mesh (if allowed) plus every relay the person listed.
    @MainActor static func live(identity: IdentityService, media: MediaStore, settings: SettingsStore) -> DecentralizedBackend {
        let store = EventStore()
        let b = DecentralizedBackend(key: identity.privateKey, agreement: identity.agreementKey, media: media, store: store)
        let relays = settings.relayURLs.compactMap(URL.init(string:))
        let mesh = settings.meshEnabled
        Task {
            if mesh { await b.attach(MeshTransport(store: store, displayName: identity.momentID)) }
            if !relays.isEmpty { await b.attach(RelayTransport(store: store, relays: relays)) }
            await b.subscribeDefaults()
        }
        return b
    }

    /// Standing relay subscriptions: everything by people I follow, everything in my Moments, my own profile echoes.
    func subscribeDefaults() async {
        let follows = (try? await following())?.map(\.toID) ?? []
        let mine = await store.all(.moment).filter { $0.author == myID || $0.tags["for"] == myID }.map(\.id)
        for t in transports.compactMap({ $0 as? RelayTransport }) {
            t.subscribe(id: "me", .init(authors: [myID]))
            t.subscribe(id: "tome", .init(tags: ["to": myID, "for": myID]))
            if !follows.isEmpty { t.subscribe(id: "follows", .init(authors: follows)) }
            if !mine.isEmpty { t.subscribe(id: "mine", .init(moments: mine)) }
        }
    }

    private var typingHandler: (@Sendable (String, String) -> Void)?
    func attach(_ t: EventTransport) {
        t.onWhisper = { [weak self] e in Task { await self?.receiveWhisper(e) } }
        transports.append(t); t.start()
    }
    private func receiveWhisper(_ e: SignedEvent) {
        guard e.kind == .seen, e.tags["typing"] == "1", let conv = e.tags["moment"], e.author != myID, abs(e.createdAt.timeIntervalSinceNow) < 30 else { return }
        typingHandler?(conv, e.author)
    }
    // MARK: - Meet (profile is a public event for the opted-in; a like is sealed to the one person it's for)
    func datingProfile(for userID: String) async throws -> DatingProfile? {
        guard let e = await store.all(.dating).last(where: { $0.author == userID }), let d = e.payload(Payloads.Dating.self), var p = d.profile else { return nil }
        var refs: [MediaRef] = []
        for (i, b) in d.photos.enumerated() { if let data = Data(base64Encoded: b) {
            let key = "\(e.id).\(i)"; var local = mediaCache[key]
            if local == nil { local = try? await media.store(data, extension: "jpg") }
            if let local { mediaCache[key] = local; refs.append(MediaRef(kind: .photo, localRef: local, remoteID: key)) }
        } }
        p.photos = refs; p.userID = userID; p.updatedAt = e.createdAt
        return p
    }
    func saveDatingProfile(_ p: DatingProfile) async throws -> DatingProfile {
        let me = try await currentUser()
        var photos: [String] = []
        for ref in p.photos.prefix(6) { if let local = ref.localRef, let d = try? await media.load(local), let t = MediaPipeline.thumbnail(d, side: 900) { photos.append(t.base64EncodedString()) } }
        var stored = p; stored.userID = myID; stored.displayName = me.displayName; stored.photos = []
        try await emit(.dating, tags: ["vis": "meet"], payload: Payloads.Dating(profile: stored, photos: photos))
        return try await datingProfile(for: myID) ?? p
    }
    func removeDatingProfile() async throws { try await emit(.dating, tags: ["vis": "meet"], payload: Payloads.Dating(profile: nil, photos: [])) }
    func datingCandidates() async throws -> [DatingProfile] {
        for t in transports { (t as? RelayTransport)?.subscribe(id: "meet", .init(kinds: ["dating", "like"])) }
        var latest: [String: SignedEvent] = [:]
        for e in await store.all(.dating) where e.author != myID && !localBlocked.contains(e.author) { latest[e.author] = e }
        var out: [DatingProfile] = []
        for id in latest.keys { if let p = try await datingProfile(for: id) { out.append(p) } }
        return out
    }
    func like(userID: String, note: String, promptQuestion: String?) async throws -> DatingLike {
        let me = try await currentUser()
        guard let their = await store.all(.profile).last(where: { $0.author == userID })?.payload(Payloads.Profile.self), let agree = their.agreePK else { throw SocialError.notFound }
        let plain = try JSONEncoder.event.encode(Payloads.Like(note: note, prompt: promptQuestion, name: me.displayName))
        let box = try SealedForPeer.seal(plain, from: agreement, to: agree)
        let e = try await emit(.like, tags: ["to": userID], payload: ["box": box])
        return DatingLike(id: e.id, fromID: myID, fromName: me.displayName, toID: userID, note: note, promptQuestion: promptQuestion, createdAt: e.createdAt)
    }
    private func openLike(_ e: SignedEvent) async -> DatingLike? {
        guard let to = e.tags["to"] else { return nil }
        if e.author == myID {
            // My own: I can't open what I sealed for them, but I remember it locally.
            let note = UserDefaults.standard.string(forKey: "meet.note.\(e.id)") ?? ""
            return DatingLike(id: e.id, fromID: myID, fromName: "You", toID: to, note: note, promptQuestion: nil, createdAt: e.createdAt)
        }
        guard to == myID, let box = e.payload([String: String].self)?["box"], let sender = await store.all(.profile).last(where: { $0.author == e.author })?.payload(Payloads.Profile.self), let agree = sender.agreePK,
              let raw = SealedForPeer.open(box, with: agreement, from: agree), let p = try? JSONDecoder.event.decode(Payloads.Like.self, from: raw) else { return nil }
        return DatingLike(id: e.id, fromID: e.author, fromName: p.name, toID: myID, note: p.note, promptQuestion: p.prompt, createdAt: e.createdAt)
    }
    func pass(userID: String) async throws { var p = Set(UserDefaults.standard.stringArray(forKey: "meet.passed.\(myID.prefix(8))") ?? []); p.insert(userID); UserDefaults.standard.set(Array(p), forKey: "meet.passed.\(myID.prefix(8))") }
    func passedUserIDs() async throws -> [String] { UserDefaults.standard.stringArray(forKey: "meet.passed.\(myID.prefix(8))") ?? [] }
    func likesReceived() async throws -> [DatingLike] {
        var out: [DatingLike] = []
        for e in await store.all(.like) where e.tags["to"] == myID && !localBlocked.contains(e.author) { if let l = await openLike(e) { out.append(l) } }
        return out
    }
    func likesSent() async throws -> [DatingLike] {
        var out: [DatingLike] = []
        for e in await store.all(.like) where e.author == myID { if let l = await openLike(e) { out.append(l) } }
        return out
    }

    // MARK: - Storefront (metadata is public; the media is sealed and the key is handed to buyers only)

    /// One key per set, kept on the creator's phone. A buyer gets it sealed to their agreement key.
    private func setKey(_ id: String) -> SymmetricKey {
        if let k = keys.load("set.\(id)") { return k }
        let k = MomentKeys.new(); keys.save(k, for: "set.\(id)"); return k
    }
    func vaultSets(creatorID: String) async throws -> [VaultSet] {
        var latest: [String: VaultSet] = [:]
        for e in await store.all(.vaultSet) where e.author == creatorID && !localBlocked.contains(e.author) {
            guard let v = e.payload(Payloads.Vault.self) else { continue }
            guard var set = v.set else { latest[e.tags["set"] ?? ""] = nil; continue }
            set.creatorID = creatorID; set.itemCount = v.itemCount
            if let c = v.cover, let d = Data(base64Encoded: c) {
                let key = "vcover.\(e.id)"
                var local = mediaCache[key]
                if local == nil { local = try? await media.store(d, extension: "jpg") }
                if let local { mediaCache[key] = local; set.cover = MediaRef(kind: .photo, localRef: local, remoteID: key) }
            }
            latest[set.id] = set
        }
        return latest.values.filter { $0.visible || creatorID == myID }.sorted { $0.createdAt > $1.createdAt }
    }
    func saveVaultSet(_ set: VaultSet, items: [VaultItem], media mediaData: [String: Data]) async throws -> VaultSet {
        let me = try await currentUser()
        var x = set; x.creatorID = myID; x.creatorName = me.displayName; x.itemCount = items.count
        if x.id.isEmpty { x.id = "set_" + UUID().uuidString }
        x.cover = nil
        let key = setKey(x.id)
        // Items (with their media inline) are sealed under the set key; only buyers ever get that key.
        var payloadItems: [[String: String]] = []
        for (i, item) in items.enumerated() {
            guard let ref = item.media, let local = ref.localRef, let d = try? await media.load(local) else { continue }
            let shrunk = item.kind == .video ? d : (MediaPipeline.thumbnail(d, side: 1600) ?? d)
            payloadItems.append(["id": item.id.isEmpty ? "vi_\(x.id)_\(i)" : item.id, "kind": item.kind.rawValue, "caption": item.caption, "media": shrunk.base64EncodedString()])
        }
        let sealed = try AES.GCM.seal(JSONEncoder.event.encode(payloadItems), using: key).combined!.base64EncodedString()
        var coverB64: String? = nil
        if let ref = set.cover, let local = ref.localRef, let d = try? await media.load(local) { coverB64 = MediaPipeline.thumbnail(d, side: 900)?.base64EncodedString() }
        try await emit(.vaultSet, tags: ["set": x.id, "price": String(x.priceMinor)], payload: Payloads.Vault(set: x, cover: coverB64, sealedItems: sealed, itemCount: items.count))
        return try await vaultSets(creatorID: myID).first { $0.id == x.id } ?? x
    }
    func deleteVaultSet(id: String) async throws {
        try await emit(.vaultSet, tags: ["set": id], payload: Payloads.Vault(set: nil, cover: nil, sealedItems: nil, itemCount: 0))
        keys.save(MomentKeys.new(), for: "set.\(id)")   // rotate: nothing new can be handed out
    }
    func vaultItems(setID: String) async throws -> [VaultItem] {
        guard let e = await store.all(.vaultSet).last(where: { $0.tags["set"] == setID }), let v = e.payload(Payloads.Vault.self), let set = v.set, let sealed = v.sealedItems else { throw SocialError.notFound }
        let key: SymmetricKey?
        if e.author == myID { key = setKey(setID) }
        else if set.isFree, let k = keys.load("set.\(setID)") { key = k }
        else { key = keys.load("set.\(setID)") }
        guard let key, let boxed = Data(base64Encoded: sealed), let box = try? AES.GCM.SealedBox(combined: boxed), let plain = try? AES.GCM.open(box, using: key),
              let rows = try? JSONDecoder.event.decode([[String: String]].self, from: plain) else { throw SocialError.notAllowed }
        var out: [VaultItem] = []
        for (i, r) in rows.enumerated() {
            var ref: MediaRef? = nil
            let kind = MediaRef.Kind(rawValue: r["kind"] ?? "") ?? .photo
            if let b = r["media"], let d = Data(base64Encoded: b) {
                let ck = "vitem.\(setID).\(i)"
                var local = mediaCache[ck]
                if local == nil { local = try? await media.store(d, extension: kind == .video ? "mp4" : "jpg") }
                if let local { mediaCache[ck] = local; ref = MediaRef(kind: kind, localRef: local, remoteID: ck) }
            }
            out.append(VaultItem(id: r["id"] ?? "\(setID)_\(i)", setID: setID, kind: kind, media: ref, caption: r["caption"] ?? "", index: i))
        }
        return out
    }
    func buyVaultSet(id: String, rail: PaymentRail, reference: String?) async throws -> VaultPurchase {
        guard let e = await store.all(.vaultSet).last(where: { $0.tags["set"] == id }), let set = e.payload(Payloads.Vault.self)?.set, e.author != myID else { throw SocialError.notAllowed }
        let me = try await currentUser()
        let ev = try await emit(.vaultBuy, tags: ["set": id, "to": e.author], payload: Payloads.Buy(amountMinor: set.priceMinor, currency: set.currency, rail: (set.isFree ? PaymentRail.none : rail).rawValue, reference: reference, name: me.displayName))
        // Ask relays for the key the creator will seal back to me.
        for t in transports { (t as? RelayTransport)?.subscribe(id: "vkeys", .init(kinds: ["vaultKey"], tags: ["to": myID])) }
        return VaultPurchase(id: ev.id, setID: id, creatorID: e.author, buyerID: myID, buyerName: me.displayName, amountMinor: set.priceMinor, currency: set.currency, rail: set.isFree ? .none : rail, reference: reference, createdAt: ev.createdAt)
    }
    private func purchase(from e: SignedEvent) -> VaultPurchase? {
        guard let setID = e.tags["set"], let to = e.tags["to"], let b = e.payload(Payloads.Buy.self) else { return nil }
        return VaultPurchase(id: e.id, setID: setID, creatorID: to, buyerID: e.author, buyerName: b.name, amountMinor: b.amountMinor, currency: b.currency, rail: PaymentRail(rawValue: b.rail) ?? .none, reference: b.reference, createdAt: e.createdAt)
    }
    func myPurchases() async throws -> [VaultPurchase] {
        await store.all(.vaultBuy).filter { $0.author == myID }.compactMap(purchase(from:)).sorted { $0.createdAt > $1.createdAt }
    }
    func vaultSales() async throws -> [VaultPurchase] {
        let sales = await store.all(.vaultBuy).filter { $0.tags["to"] == myID && !localBlocked.contains($0.author) }.compactMap(purchase(from:))
        await handOutKeys(for: sales)
        return sales.sorted { $0.createdAt > $1.createdAt }
    }
    /// The creator's phone releases the set key to whoever paid. Sealed to them; nobody else can use it.
    private func handOutKeys(for sales: [VaultPurchase]) async {
        let done = Set(await store.all(.vaultKey).filter { $0.author == myID }.map { "\($0.tags["to"] ?? "")|\($0.tags["set"] ?? "")" })
        for s in sales where !done.contains("\(s.buyerID)|\(s.setID)") {
            guard let profile = await store.all(.profile).last(where: { $0.author == s.buyerID })?.payload(Payloads.Profile.self), let agree = profile.agreePK,
                  let box = try? SealedForPeer.seal(setKey(s.setID).withUnsafeBytes { Data($0) }, from: agreement, to: agree) else { continue }
            _ = try? await emit(.vaultKey, tags: ["to": s.buyerID, "set": s.setID], payload: ["box": box])
        }
    }
    /// A key addressed to me: open it and keep it, so the set unlocks.
    private func acceptKeys() async {
        for e in await store.all(.vaultKey) where e.tags["to"] == myID {
            guard let setID = e.tags["set"], keys.load("set.\(setID)") == nil,
                  let their = await store.all(.profile).last(where: { $0.author == e.author })?.payload(Payloads.Profile.self), let agree = their.agreePK,
                  let box = e.payload([String: String].self)?["box"], let raw = SealedForPeer.open(box, with: agreement, from: agree) else { continue }
            keys.save(SymmetricKey(data: raw), for: "set.\(setID)")
        }
    }
    func bookingOffers(creatorID: String) async throws -> [BookingOffer] {
        var latest: [String: BookingOffer] = [:]
        for e in await store.all(.offer) where e.author == creatorID {
            guard let o = e.payload(Payloads.Offer.self)?.offer else { if let id = e.tags["offer"] { latest[id] = nil }; continue }
            latest[o.id] = o
        }
        return latest.values.filter { $0.active || creatorID == myID }.sorted { $0.priceMinor < $1.priceMinor }
    }
    func saveBookingOffer(_ offer: BookingOffer) async throws -> BookingOffer {
        let me = try await currentUser()
        var x = offer; x.creatorID = myID; x.creatorName = me.displayName
        if x.id.isEmpty { x.id = "offer_" + UUID().uuidString }
        try await emit(.offer, tags: ["offer": x.id], payload: Payloads.Offer(offer: x))
        return x
    }
    func deleteBookingOffer(id: String) async throws { try await emit(.offer, tags: ["offer": id], payload: Payloads.Offer(offer: nil)) }
    func requestBooking(offerID: String, creatorID: String, kind: BookingOffer.Kind, startsAt: Date, note: String, rail: PaymentRail, reference: String?) async throws -> Booking {
        guard creatorID != myID else { throw SocialError.notAllowed }
        let offer = try await bookingOffers(creatorID: creatorID).first { $0.id == offerID }
        if !offerID.isEmpty && offer == nil { throw SocialError.notFound }
        let me = try await currentUser()
        var theirName = offer?.creatorName
        if theirName == nil { theirName = (try? await user(id: creatorID))?.displayName }
        let b = Booking(id: "bk_" + UUID().uuidString, offerID: offerID, creatorID: creatorID, creatorName: theirName ?? "Creator", buyerID: myID, buyerName: me.displayName, kind: offer?.kind ?? kind, minutes: offer?.minutes ?? 0, amountMinor: offer?.priceMinor ?? 0, currency: offer?.currency ?? "INR", startsAt: startsAt, status: offer == nil ? .asked : .requested, note: note, rail: rail, reference: reference, roomID: "", createdAt: .now)
        try await emit(.booking, tags: ["booking": b.id, "to": creatorID], payload: Payloads.BookingBody(booking: b))
        return b
    }
    func quoteBooking(id: String, amountMinor: Int, currency: String, note: String) async throws -> Booking {
        guard var b = try await myBookings().first(where: { $0.id == id }), b.creatorID == myID, b.status == .asked else { throw SocialError.notAllowed }
        b.amountMinor = amountMinor; b.currency = currency; b.status = .quoted
        if !note.isBlank { b.note = b.note.isBlank ? note : b.note + "\n— " + note }
        try await emit(.booking, tags: ["booking": b.id, "to": b.buyerID], payload: Payloads.BookingBody(booking: b))
        return b
    }
    func setBookingStatus(id: String, status: Booking.Status) async throws -> Booking {
        guard var b = try await myBookings().first(where: { $0.id == id }) else { throw SocialError.notFound }
        let buyerMay: Set<Booking.Status> = [.requested, .declined, .done, .refunded]
        guard b.creatorID == myID || (b.buyerID == myID && buyerMay.contains(status)) else { throw SocialError.notAllowed }
        if status == .requested { guard b.status == .quoted, b.buyerID == myID else { throw SocialError.notAllowed } }
        b.status = status
        if status == .accepted, b.roomID.isEmpty { b.roomID = "room_" + UUID().uuidString.prefix(12) }
        try await emit(.booking, tags: ["booking": b.id, "to": b.creatorID == myID ? b.buyerID : b.creatorID], payload: Payloads.BookingBody(booking: b))
        return b
    }
    func myBookings() async throws -> [Booking] {
        var latest: [String: (Date, Booking)] = [:]
        for e in await store.all(.booking) {
            guard let b = e.payload(Payloads.BookingBody.self)?.booking, b.buyerID == myID || b.creatorID == myID else { continue }
            // Only the two of them can move it, and only the creator can accept/decline.
            let mover = e.author
            guard mover == b.buyerID || mover == b.creatorID else { continue }
            if (b.status == .accepted || b.status == .quoted) && mover != b.creatorID { continue }
            if b.status == .requested && b.amountMinor > 0 && mover != b.buyerID && mover != b.creatorID { continue }
            if (latest[b.id]?.0 ?? .distantPast) <= e.createdAt { latest[b.id] = (e.createdAt, b) }
        }
        return latest.values.map(\.1).sorted { $0.startsAt > $1.startsAt }
    }
    func creatorLinks(for userID: String) async throws -> CreatorLinks {
        await store.all(.links).last { $0.author == userID }?.payload(Payloads.Links.self)?.links ?? CreatorLinks()
    }
    func saveCreatorLinks(_ l: CreatorLinks) async throws { try await emit(.links, payload: Payloads.Links(links: l)) }

    func markSeen(conversationID: String, lastMessageID: String) async throws {
        // Don't spam the network: one event per conversation per last-message.
        if let last = await store.all(.seen).last(where: { $0.author == myID && $0.tags["moment"] == conversationID }), last.tags["last"] == lastMessageID { return }
        try await emit(.seen, tags: ["moment": conversationID, "last": lastMessageID], payload: ["v": "1"])
    }
    func seen(conversationID: String) async throws -> [String: String] {
        var out: [String: (Date, String)] = [:]
        for e in await store.all(.seen) where e.tags["moment"] == conversationID && e.tags["typing"] != "1" {
            if let last = e.tags["last"], (out[e.author]?.0 ?? .distantPast) <= e.createdAt { out[e.author] = (e.createdAt, last) }
        }
        return out.mapValues(\.1)
    }
    func setTyping(conversationID: String, typing: Bool) async {
        guard typing, let e = try? SignedEvent.make(kind: .seen, key: key, tags: ["moment": conversationID, "typing": "1"], content: "{}") else { return }
        for t in transports { t.whisper(e) }
    }
    func onTyping(_ handler: @escaping @Sendable (String, String) -> Void) async { typingHandler = handler }

    /// Called for every new event from anywhere (mesh, relay, or this phone). Invalidates derived caches
    /// and lets the UI know something changed. `foreign` is true when another person authored it.
    func startObserving(_ onForeign: @escaping @Sendable () -> Void) async {
        let me = myID
        await store.setOnNew { [weak self] e in
            guard let self else { return }
            Task { await self.invalidate(for: e) }
            if e.author != me { onForeign() }
        }
    }
    private func invalidate(for e: SignedEvent) {
        switch e.kind {
        case .profile: profileCache[e.author] = nil
        case .follow, .unfollow: if e.tags["to"] == myID { followCache.removeAll() }
        case .momentUpdate: if let m = e.tags["moment"] { coverCache[m] = nil }
        case .subscribe where e.tags["to"] == myID: Task { _ = try? await self.subscribers() }
        case .vaultBuy where e.tags["to"] == myID: Task { _ = try? await self.vaultSales() }
        case .vaultKey where e.tags["to"] == myID: Task { await self.acceptKeys() }
        case .grant where e.tags["to"] == myID: Task { await self.acceptGrant(e) }
        default: break
        }
        profileCache.removeAll()   // counts (moments/places/people) derive from everything
    }
    func detachAll() { transports.forEach { $0.stop() }; transports = [] }

    /// Sign, store, fan out.
    @discardableResult
    private func emit(_ kind: SignedEvent.Kind, tags: [String: String] = [:], payload: some Encodable, momentKey: SymmetricKey? = nil) async throws -> SignedEvent {
        let (content, enc) = try SignedEvent.encode(payload, momentKey: momentKey)
        var t = tags; if enc { t["enc"] = "1" }
        let e = try SignedEvent.make(kind: kind, key: key, tags: t, content: content)
        await store.ingest(e)
        for tr in transports { tr.publish(e) }
        return e
    }

    // MARK: - Identity

    func accountStatus() async -> AccountStatus { status }
    func setStatus(_ s: AccountStatus) { status = s }

    func currentUser() async throws -> SocialUser { (try? await user(id: myID)) ?? SocialUser(id: myID, displayName: "You", handle: "", bio: "", avatarRef: nil, isPrivateAccount: false, momentCount: 0, sharedCount: 0, placeCount: 0, peopleCount: 0, createdAt: .now, publicKey: myID, momentID: IdentityService.fingerprint(of: key.publicKey.rawRepresentation)) }

    func updateProfile(displayName: String, handle: String, bio: String, avatar: Data?) async throws -> SocialUser {
        let existing = try? await user(id: myID)
        var avatarRef: String? = existing.flatMap { _ in nil }
        if let avatar, let thumb = MediaPipeline.thumbnail(avatar, side: 256) { avatarRef = thumb.base64EncodedString() }
        let p = Payloads.Profile(displayName: displayName, handle: handle.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }, bio: bio, avatar: avatarRef, privateAccount: safety.privateAccount, momentID: IdentityService.fingerprint(of: key.publicKey.rawRepresentation), agreePK: agreement.publicKey.rawRepresentation.base64EncodedString())
        try await emit(.profile, payload: p)
        profileCache[myID] = nil
        try? await Task.sleep(for: .milliseconds(20))
        return try await user(id: myID)
    }

    func publishIdentity(publicKey: String, momentID: String) async throws {
        if (try? await user(id: myID)) == nil { _ = try await updateProfile(displayName: "You", handle: "", bio: "", avatar: nil) }
    }

    func user(id: String) async throws -> SocialUser {
        if let c = profileCache[id] { return c }
        let profiles = await store.all(.profile).filter { $0.author == id }
        guard let latest = profiles.last, let p = latest.payload(Payloads.Profile.self) else { throw SocialError.notFound }
        var avatar: MediaRef? = nil
        if let a = p.avatar, let data = Data(base64Encoded: a), let local = try? await media.store(data, extension: "jpg") { avatar = MediaRef(kind: .photo, localRef: local, remoteID: "avatar." + latest.id) }
        let mine = await momentsInvolving(id)
        let u = SocialUser(id: id, displayName: p.displayName, handle: p.handle, bio: p.bio, avatarRef: avatar, isPrivateAccount: p.privateAccount, momentCount: mine.count, sharedCount: mine.filter(\.isGroup).count, placeCount: Set(mine.compactMap(\.coarsePlace)).count, peopleCount: Set(mine.flatMap(\.memberIDs)).subtracting([id]).count, createdAt: profiles.first?.createdAt ?? .now, publicKey: id, momentID: p.momentID)
        profileCache[id] = u
        return u
    }

    func searchUsers(_ text: String) async throws -> [SocialUser] {
        let q = text.lowercased().trimmed
        var seen: [String: SocialUser] = [:]
        for e in await store.all(.profile) where e.author != myID && !localBlocked.contains(e.author) { if let u = try? await user(id: e.author) { seen[e.author] = u } }
        return seen.values.filter { q.isEmpty || $0.handle.contains(q) || $0.displayName.lowercased().contains(q) || ($0.momentID?.lowercased().contains(q) ?? false) }.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Moments (state = fold of events)

    private func momentKey(_ id: String, event: SignedEvent?) -> SymmetricKey? {
        if event?.tags["enc"] != "1" { return nil }
        return keys.load(id)
    }
    /// Key that children (sides, comments, joins) of a Moment are sealed under: the per-Moment key, or the creator key for paid ones.
    private func childKey(_ momentID: String) async -> SymmetricKey? {
        if let root = await store.get([momentID]).first, let creator = root.tags["sub"] { return creator == myID ? creatorKey() : keys.load("creator.\(creator)") }
        return keys.load(momentID)
    }
    /// My content key for subscribers-only Moments. Created on first use; rotated when a subscription lapses.
    private func creatorKey() -> SymmetricKey {
        if let k = keys.load("creator.\(myID)") { return k }
        let k = MomentKeys.new(); keys.save(k, for: "creator.\(myID)"); return k
    }

    func moment(id: String) async throws -> SocialMoment {
        guard let m = await build(id) else { throw SocialError.notFound }
        guard canSee(m) else { throw SocialError.notAllowed }
        return m
    }

    private func canSee(_ m: SocialMoment) -> Bool {
        if localBlocked.contains(m.creatorID) { return false }
        if m.memberIDs.contains(myID) || m.visibility == .publicAll || m.visibility == .subscribers { return true }
        // Anything else is encrypted; we can only build it if we hold the key.
        return keys.load(m.id) != nil
    }

    /// Folds moment + update + join + leave + contribution + comment + reaction events into one value.
    private func build(_ id: String) async -> SocialMoment? {
        let evs = await store.forMoment(id)
        var rootEvent = evs.first(where: { $0.kind == .moment && $0.id == id })
        if rootEvent == nil { rootEvent = await store.get([id]).first }
        guard let root = rootEvent, root.kind == .moment else { return nil }
        var k = momentKey(id, event: root)
        var isLocked = false
        let p: Payloads.Moment
        if let creator = root.tags["sub"] {
            // Paid Moment: everyone can read the preview; only holders of the creator key can open the rest.
            guard let env = root.payload(Payloads.Locked.self) else { return nil }
            k = creator == myID ? creatorKey() : keys.load("creator.\(creator)")
            if let k, let boxed = Data(base64Encoded: env.sealed), let box = try? AES.GCM.SealedBox(combined: boxed), let plain = try? AES.GCM.open(box, using: k), let full = try? JSONDecoder.event.decode(Payloads.Moment.self, from: plain) { p = full }
            else { p = env.preview; isLocked = true; k = nil }
        } else {
            guard let full = root.payload(Payloads.Moment.self, momentKey: k) else { return nil }
            p = full
        }
        var cover: MediaRef? = nil
        var m = SocialMoment(id: id, creatorID: root.author, creatorName: p.creatorName, title: p.title, description: p.description, coverRef: nil, createdAt: root.createdAt, startAt: p.startAt, endAt: p.endAt, locationName: p.locationName, coarsePlace: p.coarsePlace, visibility: MomentVisibility(rawValue: p.visibility) ?? .group, memberIDs: [root.author], memberNames: [p.creatorName], contributionCount: 0, mediaCount: 0, commentCount: 0, reactionCounts: [:], shareCount: 0, isLive: p.isLive, templateID: p.templateID, remixedFromID: p.remixedFromID, shareURL: inviteURL(for: id), allowsReshare: true, allowsDownload: true, allowsContributions: true, isTeaser: p.isTeaser, place: p.place, signature: root.sig, creatorPublicKey: root.author, signedAt: root.createdAt)
        var coverB64 = p.cover
        var left: Set<String> = []
        var reactions: [String: String] = [:]   // author|contribution → kind
        for e in evs where e.id != id {
            switch e.kind {
            case .momentUpdate where e.author == root.author:
                if let u = e.payload(Payloads.Update.self, momentKey: k) {
                    if let t = u.title { m.title = t }; if let d = u.description { m.description = d }; if let v = u.visibility, let vis = MomentVisibility(rawValue: v) { m.visibility = vis }
                    if let l = u.isLive { m.isLive = l }; if let a = u.allowsContributions { m.allowsContributions = a }; if let t = u.isTeaser { m.isTeaser = t }; if let c = u.cover { coverB64 = c }
                }
            case .join:
                if let j = e.payload(Payloads.Join.self, momentKey: k), !m.memberIDs.contains(e.author) { m.memberIDs.append(e.author); m.memberNames.append(j.name); left.remove(e.author) }
            case .leave:
                left.insert(e.author)
            case .contribution:
                guard m.allowsContributions || e.author == root.author else { continue }
                m.contributionCount += 1
                if let s = e.payload(Payloads.Side.self, momentKey: k) {
                    if s.media != nil { m.mediaCount += 1 }
                    if !m.memberIDs.contains(e.author) { m.memberIDs.append(e.author); m.memberNames.append(s.authorName) }
                }
            case .comment: m.commentCount += 1
            case .reaction:
                if let r = e.payload(Payloads.Reaction.self, momentKey: k) { reactions["\(e.author)|\(r.contributionID ?? "")"] = r.kind ?? "" }
            default: break
            }
        }
        for (i, id) in m.memberIDs.enumerated().reversed() where left.contains(id) && id != root.author { m.memberIDs.remove(at: i); if i < m.memberNames.count { m.memberNames.remove(at: i) } }
        for (k2, v) in reactions where k2.hasSuffix("|") && !v.isEmpty { m.reactionCounts[v, default: 0] += 1 }
        if let c = coverB64, let data = Data(base64Encoded: c) {
            if let cached = coverCache[id] { cover = cached } else if let local = try? await media.store(data, extension: "jpg") { cover = MediaRef(kind: .photo, localRef: local, remoteID: "cover." + id); coverCache[id] = cover }
        }
        m.coverRef = cover
        m.shareCount = m.memberIDs.count - 1
        m.isLocked = isLocked
        return m
    }
    private var coverCache: [String: MediaRef] = [:]

    private func inviteURL(for id: String) -> URL? {
        var c = URLComponents(); c.scheme = "moment"; c.host = "join"; c.path = "/\(id)"
        if let k = keys.load(id) { c.fragment = MomentKeys.string(k) }
        return c.url
    }

    private func momentsInvolving(_ userID: String) async -> [SocialMoment] {
        var out: [SocialMoment] = []
        for e in await store.all(.moment) { if let m = await build(e.id), m.memberIDs.contains(userID), canSee(m) { out.append(m) } }
        return out
    }

    func createMoment(_ draft: MomentDraft) async throws -> SocialMoment {
        let me = try await currentUser()
        let paid = draft.visibility == .subscribers
        let key: SymmetricKey? = paid ? creatorKey() : (draft.visibility == .publicAll ? nil : MomentKeys.new())
        let cover = draft.coverData.flatMap { MediaPipeline.thumbnail($0, side: 720) }?.base64EncodedString()
        let p = Payloads.Moment(title: draft.title, description: draft.description, startAt: draft.startAt, endAt: draft.endAt, locationName: draft.locationName, coarsePlace: draft.coarsePlace, visibility: draft.visibility.rawValue, templateID: draft.templateID, remixedFromID: draft.remixedFromID, isLive: draft.isLive, cover: cover, isTeaser: draft.isTeaser, place: draft.place, creatorName: me.displayName)
        var tags: [String: String] = ["vis": draft.visibility.rawValue]
        if let pl = draft.place { tags["place"] = pl.id; tags["geo"] = GeoCell.cell(lat: pl.latitude, lon: pl.longitude) }
        let e: SignedEvent
        if paid, let key {
            guard (try? await creatorPlan(for: myID)) != nil else { throw SocialError.backend("Set up your plan before selling a Moment.") }
            tags["sub"] = myID
            var preview = p; preview.description = ""; preview.cover = draft.coverData.flatMap { MediaPipeline.thumbnail($0, side: 360) }?.base64EncodedString()
            let sealed = try AES.GCM.seal(JSONEncoder.event.encode(p), using: key).combined!.base64EncodedString()
            e = try await emit(.moment, tags: tags, payload: Payloads.Locked(preview: preview, sealed: sealed))
        } else {
            e = try await emit(.moment, tags: tags, payload: p, momentKey: key)
        }
        // The Moment's own id is the event id; index it under itself so children can be folded.
        if let key, !paid { keys.save(key, for: e.id) }
        await store.ingest(e)
        for id in draft.initialMemberIDs { _ = try? await inviteMember(id, momentID: e.id) }
        guard let m = await build(e.id) else { throw SocialError.backend("Couldn't build the Moment.") }
        return m
    }

    private func inviteMember(_ userID: String, momentID: String) async throws {
        // Membership is a signed join by the person themselves; an invite just pre-lists them so the
        // creator's UI shows "invited" until they join. We record it as a creator-authored join on their behalf
        // with their name, which the fold treats as membership (they can leave at any time).
        let name = (try? await user(id: userID))?.displayName ?? "Invited"
        let k = keys.load(momentID)
        try await emit(.join, tags: ["moment": momentID, "for": userID], payload: Payloads.Join(name: name), momentKey: k)
    }

    func updateMoment(_ moment: SocialMoment) async throws -> SocialMoment {
        guard moment.creatorID == myID else { throw SocialError.notAllowed }
        let k = keys.load(moment.id)
        try await emit(.momentUpdate, tags: ["moment": moment.id], payload: Payloads.Update(title: moment.title, description: moment.description, visibility: moment.visibility.rawValue, isLive: moment.isLive, allowsContributions: moment.allowsContributions, isTeaser: moment.isTeaser, cover: nil), momentKey: k)
        try? await Task.sleep(for: .milliseconds(20))
        return try await self.moment(id: moment.id)
    }

    func deleteMoment(id: String) async throws {
        guard let m = await build(id), m.creatorID == myID else { throw SocialError.notAllowed }
        try await emit(.delete, tags: ["target": id, "moment": id], payload: ["reason": "deleted"])
    }

    func myMoments(cursor: String?) async throws -> FeedPage<SocialMoment> { FeedPage(items: (await momentsInvolving(myID)).filter { $0.creatorID == myID }.sorted { $0.createdAt > $1.createdAt }, cursor: nil) }
    func sharedWithMe(cursor: String?) async throws -> FeedPage<SocialMoment> { FeedPage(items: (await momentsInvolving(myID)).filter { $0.creatorID != myID }.sorted { $0.createdAt > $1.createdAt }, cursor: nil) }

    func contributions(momentID: String) async throws -> [Contribution] {
        guard let m = await build(momentID), canSee(m) else { throw SocialError.notFound }
        guard !m.isLocked else { throw SocialError.notAllowed }
        let k = await childKey(momentID)
        var out: [Contribution] = []
        for e in await store.forMoment(momentID) where e.kind == .contribution && !localBlocked.contains(e.author) {
            guard let s = e.payload(Payloads.Side.self, momentKey: k) else { continue }
            var ref: MediaRef? = nil
            if let b = s.media, let data = Data(base64Encoded: b) {
                let ext = s.mediaKind == "video" ? "mp4" : "jpg"
                var local = mediaCache[e.id]
                if local == nil { local = try? await media.store(data, extension: ext) }
                if let local { mediaCache[e.id] = local; ref = MediaRef(kind: s.mediaKind == "video" ? .video : .photo, localRef: local, remoteID: e.id, width: s.w, height: s.h) }
            }
            var counts: [String: Int] = [:]
            for r in await store.forMoment(momentID) where r.kind == .reaction { if let p = r.payload(Payloads.Reaction.self, momentKey: k), p.contributionID == e.id, let kind = p.kind { counts[kind, default: 0] += 1 } }
            out.append(Contribution(id: e.id, momentID: momentID, authorID: e.author, authorName: s.authorName, kind: Contribution.Kind(rawValue: s.kind) ?? .photo, media: ref, caption: s.caption, createdAt: e.createdAt, originalTimestamp: s.originalTimestamp, reactionCounts: counts, commentCount: 0, uploadState: .uploaded))
        }
        return out
    }
    private var mediaCache: [String: String] = [:]

    func addContribution(_ c: Contribution, mediaData: Data?) async throws -> Contribution {
        guard let m = await build(c.momentID) else { throw SocialError.notFound }
        guard m.allowsContributions, m.memberIDs.contains(myID) || m.visibility == .publicAll else { throw SocialError.notAllowed }
        let k = await childKey(c.momentID)
        var b64: String? = nil
        if let mediaData { b64 = (c.kind == .video ? mediaData : (MediaPipeline.thumbnail(mediaData, side: 1280) ?? mediaData)).base64EncodedString() }
        let s = Payloads.Side(kind: c.kind.rawValue, caption: c.caption, media: b64, mediaKind: c.kind == .video ? "video" : "photo", originalTimestamp: c.originalTimestamp, authorName: c.authorName, w: c.media?.width, h: c.media?.height)
        let e = try await emit(.contribution, tags: ["moment": c.momentID], payload: s, momentKey: k)
        var out = c; out.id = e.id; out.uploadState = .uploaded; out.createdAt = e.createdAt
        return out
    }

    func removeContribution(id: String, momentID: String) async throws {
        let evs = await store.get([id])
        let owner = await build(momentID)?.creatorID
        guard let e = evs.first, e.author == myID || owner == myID else { throw SocialError.notAllowed }
        try await emit(.delete, tags: ["target": id, "moment": momentID], payload: ["reason": "removed"])
    }

    func share(momentID: String, with userIDs: [String]) async throws -> URL {
        guard let m = await build(momentID), m.creatorID == myID else { throw SocialError.notAllowed }
        for id in userIDs where !m.memberIDs.contains(id) { try await inviteMember(id, momentID: momentID) }
        guard let url = inviteURL(for: momentID) else { throw SocialError.backend("No invite link.") }
        return url
    }

    /// `moment://join/<id>#<key>` — the key in the fragment is what makes an invite-only Moment readable.
    func acceptInvite(url: URL) async throws -> SocialMoment {
        guard url.scheme == "moment", url.host() == "join" else { throw SocialError.notFound }
        let id = url.lastPathComponent
        if let frag = url.fragment, let k = MomentKeys.key(frag) { keys.save(k, for: id) }
        // We may not have the events yet (arriving via mesh/relay); ask transports and wait briefly.
        for t in transports { (t as? RelayTransport)?.subscribe(id: "m." + id.prefix(8), .init(moments: [id])) }
        for _ in 0..<40 { if await build(id) != nil { break }; try? await Task.sleep(for: .milliseconds(250)) }
        return try await join(momentID: id)
    }

    func join(momentID: String) async throws -> SocialMoment {
        guard let m = await build(momentID), canSee(m) else { throw SocialError.notFound }
        let me = try await currentUser()
        if !m.memberIDs.contains(myID) { let ck = await childKey(momentID); try await emit(.join, tags: ["moment": momentID], payload: Payloads.Join(name: me.displayName), momentKey: ck); try? await Task.sleep(for: .milliseconds(20)) }
        return try await moment(id: momentID)
    }

    func leaveMoment(id: String) async throws {
        let ck = await childKey(id); try await emit(.leave, tags: ["moment": id], payload: ["left": "1"], momentKey: ck)
    }

    func merge(sourceID: String, into targetID: String) async throws -> SocialMoment {
        guard let src = await build(sourceID), let dst = await build(targetID), src.creatorID == myID, dst.creatorID == myID else { throw SocialError.notAllowed }
        let sk = keys.load(sourceID), dk = keys.load(targetID)
        for e in await store.forMoment(sourceID) where e.kind == .contribution { if let s = e.payload(Payloads.Side.self, momentKey: sk) { try await emit(.contribution, tags: ["moment": targetID, "movedFrom": e.id], payload: s, momentKey: dk) } }
        for (id, name) in zip(src.memberIDs, src.memberNames) where !dst.memberIDs.contains(id) { try await emit(.join, tags: ["moment": targetID, "for": id], payload: Payloads.Join(name: name), momentKey: dk) }
        try await emit(.delete, tags: ["target": sourceID, "moment": sourceID], payload: ["reason": "merged"])
        try? await Task.sleep(for: .milliseconds(30))
        return try await moment(id: targetID)
    }

    func setCover(momentID: String, data: Data) async throws -> SocialMoment {
        guard let m = await build(momentID), m.creatorID == myID else { throw SocialError.notAllowed }
        try await emit(.momentUpdate, tags: ["moment": momentID], payload: Payloads.Update(cover: MediaPipeline.thumbnail(data, side: 720)?.base64EncodedString()), momentKey: keys.load(momentID))
        coverCache[momentID] = nil
        try? await Task.sleep(for: .milliseconds(20))
        return try await moment(id: momentID)
    }

    // MARK: - Feed / discover

    func feed(cursor: String?) async throws -> FeedPage<SocialMoment> {
        let following = Set((try await following()).map(\.toID))
        var out: [SocialMoment] = []
        for e in await store.all(.moment) where !localBlocked.contains(e.author) && !localMuted.contains(e.author) {
            guard let m = await build(e.id), canSee(m) else { continue }
            let followed = following.contains(m.creatorID)
            if m.memberIDs.contains(myID) || (m.visibility == .publicAll && (followed || m.isLive)) || (m.visibility == .subscribers && (followed || !m.isLocked)) { out.append(m) }
        }
        return FeedPage(items: out.sorted { $0.createdAt > $1.createdAt }, cursor: nil)
    }

    func discover(query: String?, place: String?, cursor: String?) async throws -> FeedPage<SocialMoment> {
        var out: [SocialMoment] = []
        for e in await store.all(.moment) where e.tags["vis"] == MomentVisibility.publicAll.rawValue && !localBlocked.contains(e.author) {
            guard let m = await build(e.id) else { continue }
            if let q = query?.lowercased(), !q.isBlank, !(m.title.lowercased().contains(q) || (m.coarsePlace?.lowercased().contains(q) ?? false)) { continue }
            if let place, !place.isBlank, m.coarsePlace != place { continue }
            out.append(m)
        }
        return FeedPage(items: out.sorted { $0.contributionCount > $1.contributionCount }, cursor: nil)
    }

    func nearby(latitude: Double, longitude: Double, radiusKm: Double) async throws -> [SocialMoment] {
        let cells = Set(GeoCell.cells(lat: latitude, lon: longitude, radiusKm: radiusKm))
        for t in transports { (t as? RelayTransport)?.subscribe(id: "geo", .init(kinds: ["moment", "now"], geo: Array(cells.prefix(400)))) }
        var out: [SocialMoment] = []
        for e in await store.all(.moment) where e.tags["vis"] == MomentVisibility.publicAll.rawValue {
            guard let g = e.tags["geo"], cells.contains(g) else { continue }
            if let m = await build(e.id), let p = m.place, p.distance(fromLatitude: latitude, longitude: longitude) <= radiusKm, !localBlocked.contains(m.creatorID) { out.append(m) }
        }
        return out.sorted { ($0.place!.distance(fromLatitude: latitude, longitude: longitude)) < ($1.place!.distance(fromLatitude: latitude, longitude: longitude)) }
    }

    func nowNearby(latitude: Double, longitude: Double, radiusKm: Double) async throws -> [NowPost] {
        let cells = Set(GeoCell.cells(lat: latitude, lon: longitude, radiusKm: radiusKm))
        return (try await nowFeed(all: true)).filter { n in guard let p = n.place, let g = Optional(GeoCell.cell(lat: p.latitude, lon: p.longitude)), cells.contains(g) else { return false }; return p.distance(fromLatitude: latitude, longitude: longitude) <= radiusKm && n.authorID != myID ? (n.discoverable || followsMe(n.authorID)) : true }
    }

    func moments(atPlace placeID: String) async throws -> [SocialMoment] {
        var out: [SocialMoment] = []
        for e in await store.all(.moment) where e.tags["place"] == placeID { if let m = await build(e.id), canSee(m) { out.append(m) } }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Claims (signed, first valid claim wins)

    func claim(for placeID: String) async throws -> PlaceClaim? {
        guard let e = await store.all(.claim).first(where: { $0.tags["place"] == placeID }), let p = e.payload(Payloads.Claim.self) else { return nil }
        return PlaceClaim(id: placeID, placeID: placeID, ownerID: e.author, ownerName: p.ownerName, businessName: p.businessName, role: p.role, note: p.note, verified: false, createdAt: e.createdAt)
    }
    func saveClaim(_ c: PlaceClaim) async throws -> PlaceClaim {
        if let existing = try await claim(for: c.placeID), existing.ownerID != myID { throw SocialError.notAllowed }
        try await emit(.claim, tags: ["place": c.placeID], payload: Payloads.Claim(businessName: c.businessName, role: c.role, note: c.note, ownerName: c.ownerName))
        var out = c; out.ownerID = myID; out.verified = false; return out
    }
    func myClaims() async throws -> [PlaceClaim] {
        var out: [PlaceClaim] = []
        for e in await store.all(.claim) where e.author == myID { if let pid = e.tags["place"], let c = try await claim(for: pid), c.ownerID == myID, !out.contains(where: { $0.placeID == pid }) { out.append(c) } }
        return out
    }

    // MARK: - Engagement

    func comments(momentID: String) async throws -> [MomentComment] {
        let k = await childKey(momentID)
        return await store.forMoment(momentID).filter { $0.kind == .comment && !localBlocked.contains($0.author) }.compactMap { e in e.payload(Payloads.Comment.self, momentKey: k).map { MomentComment(id: e.id, momentID: momentID, contributionID: $0.contributionID, authorID: e.author, authorName: $0.authorName, text: $0.text, createdAt: e.createdAt) } }
    }
    func addComment(_ c: MomentComment) async throws -> MomentComment {
        guard ContentModeration.check(c.text) == .ok, let m = await build(c.momentID), canSee(m) else { throw SocialError.notAllowed }
        let e = try await emit(.comment, tags: ["moment": c.momentID], payload: Payloads.Comment(text: c.text, contributionID: c.contributionID, authorName: c.authorName), momentKey: await childKey(c.momentID))
        var out = c; out.id = e.id; out.authorID = myID; return out
    }
    func deleteComment(id: String, momentID: String) async throws { try await emit(.delete, tags: ["target": id, "moment": momentID], payload: ["reason": "removed"]) }
    func react(momentID: String, contributionID: String?, kind: ReactionKind?) async throws {
        let ck = await childKey(momentID); try await emit(.reaction, tags: ["moment": momentID], payload: Payloads.Reaction(kind: kind?.rawValue, contributionID: contributionID), momentKey: ck)
    }
    func myReactions(momentID: String) async throws -> [MomentReaction] {
        let k = await childKey(momentID)
        var latest: [String: (SignedEvent, Payloads.Reaction)] = [:]
        for e in await store.forMoment(momentID) where e.kind == .reaction && e.author == myID { if let p = e.payload(Payloads.Reaction.self, momentKey: k) { latest[p.contributionID ?? ""] = (e, p) } }
        return latest.values.compactMap { (e, p) in p.kind.flatMap(ReactionKind.init(rawValue:)).map { MomentReaction(id: e.id, momentID: momentID, contributionID: p.contributionID, authorID: myID, kind: $0, createdAt: e.createdAt) } }
    }

    // MARK: - NOW

    func postNow(_ post: NowPost, mediaData: Data?) async throws -> NowPost {
        guard ContentModeration.check(post.text) == .ok else { throw SocialError.notAllowed }
        var tags: [String: String] = ["exp": String(Int(post.expiresAt.timeIntervalSince1970))]
        if let p = post.place { tags["place"] = p.id; tags["geo"] = GeoCell.cell(lat: p.latitude, lon: p.longitude) }
        if safety.allowDiscoverByLocation { tags["disc"] = "1" }
        let e = try await emit(.now, tags: tags, payload: Payloads.Now(text: post.text, media: mediaData.flatMap { MediaPipeline.thumbnail($0, side: 1080) }?.base64EncodedString(), expiresAt: post.expiresAt, coarsePlace: post.coarsePlace, activity: post.activity.rawValue, place: post.place, authorName: post.authorName))
        var out = post; out.id = e.id; out.authorID = myID; return out
    }
    private func followsMe(_ id: String) -> Bool { followCache.contains(id) }
    private var followCache: Set<String> = []
    func nowFeed() async throws -> [NowPost] { try await nowFeed(all: false) }
    private func nowFeed(all: Bool) async throws -> [NowPost] {
        let following = Set((try await following()).map(\.toID))
        let joins = await store.all(.nowJoin)
        var out: [NowPost] = []
        for e in await store.all(.now) where !localBlocked.contains(e.author) && !localMuted.contains(e.author) {
            guard let p = e.payload(Payloads.Now.self), p.expiresAt > .now else { continue }
            if !all && e.author != myID && !following.contains(e.author) { continue }
            var ref: MediaRef? = nil
            if let b = p.media, let d = Data(base64Encoded: b) {
                var local = mediaCache[e.id]
                if local == nil { local = try? await media.store(d, extension: "jpg") }
                if let local { mediaCache[e.id] = local; ref = MediaRef(kind: .photo, localRef: local, remoteID: e.id) }
            }
            let js = joins.filter { $0.tags["now"] == e.id }
            var n = NowPost(id: e.id, authorID: e.author, authorName: p.authorName, text: p.text, media: ref, createdAt: e.createdAt, expiresAt: p.expiresAt, coarsePlace: p.coarsePlace, savedToMomentID: nil, activity: NowPost.Activity(rawValue: p.activity) ?? .none, place: p.place, joinerIDs: js.map(\.author), joinerNames: js.compactMap { $0.payload(Payloads.Join.self)?.name })
            n.discoverable = e.tags["disc"] == "1"
            out.append(n)
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }
    func deleteNow(id: String) async throws { try await emit(.delete, tags: ["target": id], payload: ["reason": "removed"]) }
    func joinNow(id: String) async throws -> NowPost {
        let me = try await currentUser()
        try await emit(.nowJoin, tags: ["now": id], payload: Payloads.Join(name: me.displayName))
        try? await Task.sleep(for: .milliseconds(20))
        guard let n = try await nowFeed(all: true).first(where: { $0.id == id }) else { throw SocialError.notFound }
        return n
    }

    // MARK: - Graph & safety (follows are public signed events; blocks/mutes stay local)

    func follow(userID: String, close: Bool) async throws { try await emit(.follow, tags: ["to": userID, "close": close ? "1" : "0"], payload: ["ok": "1"]); followCache.insert(userID) }
    func unfollow(userID: String) async throws { try await emit(.unfollow, tags: ["to": userID], payload: ["ok": "1"]) }
    func following() async throws -> [Follow] { await follows(from: myID) }
    func followers() async throws -> [Follow] {
        var latest: [String: (Bool, Date, Bool)] = [:]
        for e in await store.all(.follow) + (await store.all(.unfollow)) where e.tags["to"] == myID { latest[e.author] = (e.kind == .follow, e.createdAt, e.tags["close"] == "1") }
        followCache = Set(latest.filter { $0.value.0 }.keys)
        return latest.compactMap { $0.value.0 ? Follow(fromID: $0.key, toID: myID, createdAt: $0.value.1, isClose: $0.value.2) : nil }
    }
    private func follows(from author: String) async -> [Follow] {
        var latest: [String: (Bool, Date, Bool)] = [:]
        for e in await store.all(.follow) + (await store.all(.unfollow)) where e.author == author { if let to = e.tags["to"] { latest[to] = (e.kind == .follow, e.createdAt, e.tags["close"] == "1") } }
        return latest.compactMap { $0.value.0 ? Follow(fromID: author, toID: $0.key, createdAt: $0.value.1, isClose: $0.value.2) : nil }
    }
    func block(userID: String) async throws { localBlocked.insert(userID); UserDefaults.standard.set(Array(localBlocked), forKey: "mesh.blocked"); try? await unfollow(userID: userID) }
    func unblock(userID: String) async throws { localBlocked.remove(userID); UserDefaults.standard.set(Array(localBlocked), forKey: "mesh.blocked") }
    func blockedUserIDs() async throws -> [String] { Array(localBlocked).sorted() }
    func mute(userID: String) async throws { localMuted.insert(userID); UserDefaults.standard.set(Array(localMuted), forKey: "mesh.muted") }
    func mutedUserIDs() async throws -> [String] { Array(localMuted).sorted() }
    func report(_ report: UserReport) async throws { try await emit(.report, tags: [:], payload: Payloads.Report(targetUserID: report.targetUserID, targetMomentID: report.targetMomentID, reason: report.reason.rawValue, details: report.details)) }
    func safetySettings() async throws -> SafetySettings { safety }
    func updateSafetySettings(_ s: SafetySettings) async throws { safety = s; if let d = try? JSONEncoder().encode(s) { try? Keychain.set(d, for: "mesh.safety") } }

    // MARK: - Inbox (derived; DMs are Moments with two members, kept simple)

    func activity(cursor: String?) async throws -> FeedPage<ActivityItem> {
        var items: [ActivityItem] = []
        for m in await momentsInvolving(myID) {
            for c in (try? await contributions(momentID: m.id)) ?? [] where c.authorID != myID && c.createdAt.daysUntil(.now) <= 14 {
                items.append(ActivityItem(id: "act." + c.id, kind: .contribution, actorName: c.authorName, momentID: m.id, momentTitle: m.title, text: "\(c.authorName) added \(c.kind == .text ? "a note" : "a \(c.kind.rawValue)") to \(m.title)", createdAt: c.createdAt, read: false))
            }
        }
        for f in try await followers() where f.createdAt.daysUntil(.now) <= 14 { let n = (try? await user(id: f.fromID))?.displayName ?? "Someone"; items.append(ActivityItem(id: "fol." + f.fromID, kind: .follow, actorName: n, momentID: nil, momentTitle: nil, text: "\(n) started following you", createdAt: f.createdAt, read: false)) }
        return FeedPage(items: items.sorted { $0.createdAt > $1.createdAt }, cursor: nil)
    }
    func invites() async throws -> [MomentInvite] { (try await sharedWithMe(cursor: nil)).items.map { MomentInvite(id: "inv." + $0.id, momentID: $0.id, momentTitle: $0.title, inviterID: $0.creatorID, inviterName: $0.creatorName, shareURL: $0.shareURL, createdAt: $0.createdAt, accepted: true) } }
    func markActivityRead() async throws {}
    func conversations() async throws -> [Conversation] {
        var out: [Conversation] = []
        for m in await momentsInvolving(myID) where m.templateID == "dm" || m.templateID?.hasPrefix("dmg:") == true {
            let last = (try? await messages(conversationID: m.id))?.last { !$0.isReaction }
            let gid = m.templateID.flatMap { $0.hasPrefix("dmg:") ? String($0.dropFirst(4)) : nil }
            out.append(Conversation(id: m.id, participantIDs: m.memberIDs, participantNames: m.memberNames, lastMessage: last.map { $0.text.isEmpty ? ($0.momentID != nil ? "Shared a Moment" : "Photo") : $0.text } ?? "", updatedAt: last?.createdAt ?? m.createdAt, title: gid != nil ? m.title : nil, emoji: nil, groupID: gid))
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }
    func messages(conversationID: String) async throws -> [DirectMessage] {
        let k = await childKey(conversationID)
        var out: [DirectMessage] = []
        for e in await store.forMoment(conversationID) where e.kind == .comment && !localBlocked.contains(e.author) {
            guard let p = e.payload(Payloads.Comment.self, momentKey: k) else { continue }
            var ref: MediaRef? = nil
            if let b = p.media, let d = Data(base64Encoded: b) {
                let kind = MediaRef.Kind(rawValue: p.mediaKind ?? "") ?? .photo
                var local = mediaCache[e.id]
                if local == nil { local = try? await media.store(d, extension: kind == .voice ? "m4a" : "jpg") }
                if let local { mediaCache[e.id] = local; ref = MediaRef(kind: kind, localRef: local, remoteID: e.id, durationSeconds: p.duration) }
            }
            out.append(DirectMessage(id: e.id, conversationID: conversationID, authorID: e.author, authorName: p.authorName, text: p.text, media: ref, momentID: p.contributionID, createdAt: e.createdAt, replyToID: p.replyTo))
        }
        return out
    }
    func send(_ message: DirectMessage, mediaData: Data?) async throws -> DirectMessage {
        guard ContentModeration.check(message.text) == .ok, let m = await build(message.conversationID), m.memberIDs.contains(myID) else { throw SocialError.notAllowed }
        let isVoice = message.media?.kind == .voice
        let b64 = mediaData.flatMap { isVoice ? $0 : (MediaPipeline.thumbnail($0, side: 1280) ?? $0) }?.base64EncodedString()
        let e = try await emit(.comment, tags: ["moment": message.conversationID], payload: Payloads.Comment(text: message.text, contributionID: message.momentID, authorName: message.authorName, media: b64, replyTo: message.replyToID, mediaKind: message.media?.kind.rawValue, duration: message.media?.durationSeconds), momentKey: await childKey(message.conversationID))
        var out = message; out.id = e.id; out.authorID = myID; out.createdAt = e.createdAt; return out
    }
    func conversation(forGroup group: SocialGroup) async throws -> Conversation {
        if let c = try await conversations().first(where: { $0.groupID == group.id }) { return c }
        guard group.ownerID == myID else { throw SocialError.notFound }
        let m = try await createMoment(MomentDraft(title: group.name, description: "", visibility: .group, templateID: "dmg:\(group.id)", initialMemberIDs: group.memberIDs.filter { $0 != myID }))
        return Conversation(id: m.id, participantIDs: m.memberIDs, participantNames: m.memberNames, lastMessage: "", updatedAt: .now, title: group.name, emoji: group.emoji, groupID: group.id)
    }
    func conversation(with userID: String) async throws -> Conversation {
        if let c = try await conversations().first(where: { Set($0.participantIDs) == Set([myID, userID]) }) { return c }
        let other = try await user(id: userID)
        let m = try await createMoment(MomentDraft(title: "Chat with \(other.displayName)", description: "", visibility: .group, templateID: "dm", initialMemberIDs: [userID]))
        return Conversation(id: m.id, participantIDs: m.memberIDs, participantNames: m.memberNames, lastMessage: "", updatedAt: .now)
    }

    // MARK: - Groups (a signed group record by the owner)

    func groups() async throws -> [SocialGroup] {
        var latest: [String: SignedEvent] = [:]
        for e in await store.all(.group) { if let gid = e.tags["group"] { if let prev = latest[gid], prev.author != e.author { continue }; latest[gid] = e } }
        return latest.compactMap { (gid, e) in e.payload(Payloads.Group.self).flatMap { p in p.memberIDs.contains(myID) ? SocialGroup(id: gid, ownerID: e.author, name: p.name, emoji: p.emoji, memberIDs: p.memberIDs, memberNames: p.memberNames, conversationID: nil, createdAt: e.createdAt) : nil } }
    }
    func saveGroup(_ g: SocialGroup) async throws -> SocialGroup {
        var out = g; if out.ownerID.isEmpty { out.ownerID = myID }
        guard out.ownerID == myID else { throw SocialError.notAllowed }
        if !out.memberIDs.contains(myID) { out.memberIDs.insert(myID, at: 0); out.memberNames.insert((try? await currentUser())?.displayName ?? "You", at: 0) }
        try await emit(.group, tags: ["group": out.id], payload: Payloads.Group(name: out.name, emoji: out.emoji, memberIDs: out.memberIDs, memberNames: out.memberNames, ownerID: myID))
        return out
    }
    func leaveGroup(id: String) async throws {
        guard var g = try await groups().first(where: { $0.id == id }) else { return }
        if g.ownerID == myID { try await emit(.group, tags: ["group": id], payload: Payloads.Group(name: g.name, emoji: g.emoji, memberIDs: [], memberNames: [], ownerID: myID)); return }
        g.memberIDs.removeAll { $0 == myID }
        // Non-owners can't rewrite the owner's record; membership is honoured locally by hiding it.
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: "mesh.leftGroups") ?? []) + [id], forKey: "mesh.leftGroups")
    }

    // MARK: - Collections (local-only, private)

    private var collectionsFile: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "MomentMesh/collections.json") }
    func collections() async throws -> [MomentCollection] { (try? JSONDecoder().decode([MomentCollection].self, from: Data(contentsOf: collectionsFile))) ?? [] }
    func saveCollection(_ c: MomentCollection) async throws -> MomentCollection {
        var all = try await collections(); all.removeAll { $0.id == c.id }; all.append(c)
        try JSONEncoder().encode(all).write(to: collectionsFile, options: .atomic); return c
    }
    func deleteCollection(id: String) async throws { var all = try await collections(); all.removeAll { $0.id == id }; try JSONEncoder().encode(all).write(to: collectionsFile, options: .atomic) }

    // MARK: - Media

    func download(_ ref: MediaRef) async throws -> Data {
        if let local = ref.localRef, let data = try? await media.load(local) { return data }
        throw SocialError.notFound
    }

    // MARK: - Creator economy (plan/subscribe/grant events; the creator's phone hands paying people the key)

    func creatorPlan(for userID: String) async throws -> CreatorPlan? {
        guard let e = await store.all(.plan).last(where: { $0.author == userID }), let p = e.payload(Payloads.Plan.self), p.tier != "none" else { return nil }
        let tier = CreatorPlan.Tier(rawValue: p.tier) ?? .t1
        return CreatorPlan(creatorID: userID, creatorName: p.creatorName, title: p.title, pitch: p.pitch, priceMinor: p.priceMinor ?? Int(tier.referenceAmount * 100), currency: p.currency ?? "INR", perks: p.perks, payoutHint: p.payoutHint, createdAt: e.createdAt)
    }
    func saveCreatorPlan(_ plan: CreatorPlan) async throws -> CreatorPlan {
        let me = try await currentUser()
        try await emit(.plan, payload: Payloads.Plan(title: plan.title, pitch: plan.pitch, tier: plan.tier.rawValue, perks: plan.perks, payoutHint: plan.payoutHint, creatorName: me.displayName, priceMinor: plan.priceMinor, currency: plan.currency))
        _ = creatorKey()
        try? await Task.sleep(for: .milliseconds(20))
        return try await creatorPlan(for: myID) ?? plan
    }
    func removeCreatorPlan() async throws {
        try await emit(.plan, payload: Payloads.Plan(title: "", pitch: "", tier: "none", perks: [], payoutHint: "", creatorName: "", priceMinor: 0, currency: "INR"))
        keys.save(MomentKeys.new(), for: "creator.\(myID)")   // rotate: nothing new is readable with old grants
    }
    func subscribe(to creatorID: String, tier: CreatorPlan.Tier, transactionID: String?, days: Int) async throws -> CreatorSubscription {
        guard creatorID != myID, (try await creatorPlan(for: creatorID)) != nil else { throw SocialError.notAllowed }
        let me = try await currentUser()
        let existing = (try await mySubscriptions()).first { $0.creatorID == creatorID && $0.isActive }
        let start = existing?.expiresAt ?? .now
        let exp = start.addingTimeInterval(Double(days) * 86400)
        let e = try await emit(.subscribe, tags: ["to": creatorID, "exp": String(Int(exp.timeIntervalSince1970))], payload: Payloads.Subscribe(tier: tier.rawValue, days: days, transactionID: transactionID, name: me.displayName))
        for t in transports { (t as? RelayTransport)?.subscribe(id: "grants", .init(kinds: ["grant"], tags: ["to": myID])) }
        return CreatorSubscription(id: e.id, subscriberID: myID, subscriberName: me.displayName, creatorID: creatorID, tier: tier, startedAt: e.createdAt, expiresAt: exp, transactionID: transactionID)
    }
    private func subscription(from e: SignedEvent) -> CreatorSubscription? {
        guard let to = e.tags["to"], let expS = e.tags["exp"], let exp = Double(expS), let p = e.payload(Payloads.Subscribe.self) else { return nil }
        return CreatorSubscription(id: e.id, subscriberID: e.author, subscriberName: p.name, creatorID: to, tier: CreatorPlan.Tier(rawValue: p.tier) ?? .t1, startedAt: e.createdAt, expiresAt: Date(timeIntervalSince1970: exp), transactionID: p.transactionID)
    }
    func mySubscriptions() async throws -> [CreatorSubscription] {
        var latest: [String: CreatorSubscription] = [:]
        for e in await store.all(.subscribe) where e.author == myID { if let s = subscription(from: e) { if let prev = latest[s.creatorID], prev.expiresAt > s.expiresAt { continue }; latest[s.creatorID] = s } }
        return latest.values.sorted { $0.expiresAt > $1.expiresAt }
    }
    func subscribers() async throws -> [CreatorSubscription] {
        var latest: [String: CreatorSubscription] = [:]
        for e in await store.all(.subscribe) where e.tags["to"] == myID { if let s = subscription(from: e) { if let prev = latest[s.subscriberID], prev.expiresAt > s.expiresAt { continue }; latest[s.subscriberID] = s } }
        let list = latest.values.sorted { $0.startedAt > $1.startedAt }
        await grantPending(list)
        return list
    }
    func tip(creatorID: String, momentID: String?, amount: CreatorTip.Amount, note: String, transactionID: String?) async throws -> CreatorTip {
        guard creatorID != myID, (try await creatorPlan(for: creatorID)) != nil else { throw SocialError.notAllowed }
        let me = try await currentUser()
        var tags = ["to": creatorID]; if let momentID { tags["about"] = momentID }
        let e = try await emit(.tip, tags: tags, payload: Payloads.Tip(amount: amount.rawValue, note: note, transactionID: transactionID, name: me.displayName))
        return CreatorTip(id: e.id, fromID: myID, fromName: me.displayName, creatorID: creatorID, momentID: momentID, amount: amount, note: note, createdAt: e.createdAt, transactionID: transactionID)
    }
    func tips() async throws -> [CreatorTip] {
        await store.all(.tip).filter { $0.tags["to"] == myID }.compactMap { e in e.payload(Payloads.Tip.self).map { CreatorTip(id: e.id, fromID: e.author, fromName: $0.name, creatorID: myID, momentID: e.tags["about"], amount: CreatorTip.Amount(rawValue: $0.amount) ?? .small, note: $0.note, createdAt: e.createdAt, transactionID: $0.transactionID) } }.sorted { $0.createdAt > $1.createdAt }
    }
    /// For every active subscriber who doesn't yet hold my current key, seal it to their agreement key. Idempotent.
    private func grantPending(_ subs: [CreatorSubscription]) async {
        guard keys.load("creator.\(myID)") != nil else { return }
        let k = creatorKey()
        let fingerprint = SHA256.hash(data: k.withUnsafeBytes { Data($0) }).prefix(4).map { String(format: "%02x", $0) }.joined()
        let granted = Set(await store.all(.grant).filter { $0.author == myID && $0.tags["key"] == fingerprint }.compactMap { $0.tags["to"] })
        for s in subs where s.isActive && !granted.contains(s.subscriberID) {
            guard let profile = await store.all(.profile).last(where: { $0.author == s.subscriberID })?.payload(Payloads.Profile.self), let agree = profile.agreePK,
                  let box = try? SealedForPeer.seal(k.withUnsafeBytes { Data($0) }, from: agreement, to: agree) else { continue }
            _ = try? await emit(.grant, tags: ["to": s.subscriberID, "key": fingerprint, "exp": String(Int(s.expiresAt.timeIntervalSince1970))], payload: ["box": box])
        }
    }
    /// A grant addressed to me: open it with my agreement key and keep the creator key.
    private func acceptGrant(_ e: SignedEvent) async {
        guard e.tags["to"] == myID, let creatorProfile = await store.all(.profile).last(where: { $0.author == e.author })?.payload(Payloads.Profile.self), let agree = creatorProfile.agreePK,
              let box = e.payload([String: String].self)?["box"], let raw = SealedForPeer.open(box, with: agreement, from: agree) else { return }
        keys.save(SymmetricKey(data: raw), for: "creator.\(e.author)")
        coverCache.removeAll()
    }
    /// Creator side: react to new subscriptions as they arrive so people get in without the creator opening the app screen.
    func processGrants() async {
        _ = try? await subscribers()
        for e in await store.all(.grant) where e.tags["to"] == myID { await acceptGrant(e) }
        _ = try? await vaultSales()   // hand set keys to whoever paid
        await acceptKeys()
    }

    // MARK: - Sync stats

    func peerCount() -> Int { transports.compactMap { $0 as? MeshTransport }.map(\.peers).reduce(0, +) }
    func relayCount() -> Int { transports.compactMap { $0 as? RelayTransport }.map { $0.connected.count }.reduce(0, +) }
    func eventCount() async -> Int { await store.count }
}
