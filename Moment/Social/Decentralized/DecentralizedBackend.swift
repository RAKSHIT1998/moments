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
    private let media: MediaStore
    let keys: MomentKeys
    private var transports: [EventTransport] = []
    private var profileCache: [String: SocialUser] = [:]
    private var localBlocked: Set<String> = []
    private var localMuted: Set<String> = []
    private var safety = SafetySettings()
    private var status: AccountStatus = .available

    struct Payloads {
        struct Profile: Codable { var displayName: String; var handle: String; var bio: String; var avatar: String?; var privateAccount: Bool; var momentID: String }
        struct Moment: Codable { var title: String; var description: String; var startAt: Date?; var endAt: Date?; var locationName: String?; var coarsePlace: String?; var visibility: String; var templateID: String?; var remixedFromID: String?; var isLive: Bool; var cover: String?; var isTeaser: Bool; var place: SocialPlace?; var creatorName: String }
        struct Update: Codable { var title: String?; var description: String?; var visibility: String?; var isLive: Bool?; var allowsContributions: Bool?; var isTeaser: Bool?; var cover: String? }
        struct Side: Codable { var kind: String; var caption: String; var media: String?; var mediaKind: String?; var originalTimestamp: Date?; var authorName: String; var w: Int?; var h: Int? }
        struct Comment: Codable { var text: String; var contributionID: String?; var authorName: String }
        struct Reaction: Codable { var kind: String?; var contributionID: String? }
        struct Now: Codable { var text: String; var media: String?; var expiresAt: Date; var coarsePlace: String?; var activity: String; var place: SocialPlace?; var authorName: String }
        struct Join: Codable { var name: String }
        struct Group: Codable { var name: String; var emoji: String; var memberIDs: [String]; var memberNames: [String]; var ownerID: String }
        struct Claim: Codable { var businessName: String; var role: String; var note: String; var ownerName: String }
        struct Report: Codable { var targetUserID: String?; var targetMomentID: String?; var reason: String; var details: String }
    }

    init(key: Curve25519.Signing.PrivateKey, media: MediaStore, store: EventStore? = nil, keys: MomentKeys = MomentKeys()) {
        self.key = key; self.media = media; self.keys = keys
        self.store = store ?? EventStore()
        if let raw = Keychain.get("mesh.safety"), let s = try? JSONDecoder().decode(SafetySettings.self, from: raw) { safety = s }
        localBlocked = Set(UserDefaults.standard.stringArray(forKey: "mesh.blocked") ?? [])
        localMuted = Set(UserDefaults.standard.stringArray(forKey: "mesh.muted") ?? [])
    }

    var myID: String { key.publicKey.rawRepresentation.base64EncodedString() }

    /// Wires the production transports: local mesh (if allowed) plus every relay the person listed.
    @MainActor static func live(identity: IdentityService, media: MediaStore, settings: SettingsStore) -> DecentralizedBackend {
        let store = EventStore()
        let b = DecentralizedBackend(key: identity.privateKey, media: media, store: store)
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

    func attach(_ t: EventTransport) { transports.append(t); t.start() }

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
        default: break
        }
        profileCache.removeAll()   // counts (moments/places/people) derive from everything
    }
    func detachAll() { transports.forEach { $0.stop() }; transports = [] }

    /// Sign, store, fan out.
    @discardableResult
    private func emit(_ kind: SignedEvent.Kind, tags: [String: String] = [:], payload: some Encodable, momentKey: SymmetricKey? = nil) throws -> SignedEvent {
        let (content, enc) = try SignedEvent.encode(payload, momentKey: momentKey)
        var t = tags; if enc { t["enc"] = "1" }
        let e = try SignedEvent.make(kind: kind, key: key, tags: t, content: content)
        Task { await store.ingest(e) }
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
        let p = Payloads.Profile(displayName: displayName, handle: handle.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }, bio: bio, avatar: avatarRef, privateAccount: safety.privateAccount, momentID: IdentityService.fingerprint(of: key.publicKey.rawRepresentation))
        try emit(.profile, payload: p)
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

    func moment(id: String) async throws -> SocialMoment {
        guard let m = await build(id) else { throw SocialError.notFound }
        guard canSee(m) else { throw SocialError.notAllowed }
        return m
    }

    private func canSee(_ m: SocialMoment) -> Bool {
        if localBlocked.contains(m.creatorID) { return false }
        if m.memberIDs.contains(myID) || m.visibility == .publicAll { return true }
        // Anything else is encrypted; we can only build it if we hold the key.
        return keys.load(m.id) != nil
    }

    /// Folds moment + update + join + leave + contribution + comment + reaction events into one value.
    private func build(_ id: String) async -> SocialMoment? {
        let evs = await store.forMoment(id)
        var rootEvent = evs.first(where: { $0.kind == .moment && $0.id == id })
        if rootEvent == nil { rootEvent = await store.get([id]).first }
        guard let root = rootEvent, root.kind == .moment else { return nil }
        let k = momentKey(id, event: root)
        guard let p = root.payload(Payloads.Moment.self, momentKey: k) else { return nil }
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
        let key: SymmetricKey? = draft.visibility == .publicAll ? nil : MomentKeys.new()
        let cover = draft.coverData.flatMap { MediaPipeline.thumbnail($0, side: 720) }?.base64EncodedString()
        let p = Payloads.Moment(title: draft.title, description: draft.description, startAt: draft.startAt, endAt: draft.endAt, locationName: draft.locationName, coarsePlace: draft.coarsePlace, visibility: draft.visibility.rawValue, templateID: draft.templateID, remixedFromID: draft.remixedFromID, isLive: draft.isLive, cover: cover, isTeaser: draft.isTeaser, place: draft.place, creatorName: me.displayName)
        var tags: [String: String] = ["vis": draft.visibility.rawValue]
        if let pl = draft.place { tags["place"] = pl.id; tags["geo"] = GeoCell.cell(lat: pl.latitude, lon: pl.longitude) }
        let e = try emit(.moment, tags: tags, payload: p, momentKey: key)
        // The Moment's own id is the event id; index it under itself so children can be folded.
        if let key { keys.save(key, for: e.id) }
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
        try emit(.join, tags: ["moment": momentID, "for": userID], payload: Payloads.Join(name: name), momentKey: k)
    }

    func updateMoment(_ moment: SocialMoment) async throws -> SocialMoment {
        guard moment.creatorID == myID else { throw SocialError.notAllowed }
        let k = keys.load(moment.id)
        try emit(.momentUpdate, tags: ["moment": moment.id], payload: Payloads.Update(title: moment.title, description: moment.description, visibility: moment.visibility.rawValue, isLive: moment.isLive, allowsContributions: moment.allowsContributions, isTeaser: moment.isTeaser, cover: nil), momentKey: k)
        try? await Task.sleep(for: .milliseconds(20))
        return try await self.moment(id: moment.id)
    }

    func deleteMoment(id: String) async throws {
        guard let m = await build(id), m.creatorID == myID else { throw SocialError.notAllowed }
        try emit(.delete, tags: ["target": id, "moment": id], payload: ["reason": "deleted"])
    }

    func myMoments(cursor: String?) async throws -> FeedPage<SocialMoment> { FeedPage(items: (await momentsInvolving(myID)).filter { $0.creatorID == myID }.sorted { $0.createdAt > $1.createdAt }, cursor: nil) }
    func sharedWithMe(cursor: String?) async throws -> FeedPage<SocialMoment> { FeedPage(items: (await momentsInvolving(myID)).filter { $0.creatorID != myID }.sorted { $0.createdAt > $1.createdAt }, cursor: nil) }

    func contributions(momentID: String) async throws -> [Contribution] {
        guard let m = await build(momentID), canSee(m) else { throw SocialError.notFound }
        let k = keys.load(momentID)
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
        let k = keys.load(c.momentID)
        var b64: String? = nil
        if let mediaData { b64 = (c.kind == .video ? mediaData : (MediaPipeline.thumbnail(mediaData, side: 1280) ?? mediaData)).base64EncodedString() }
        let s = Payloads.Side(kind: c.kind.rawValue, caption: c.caption, media: b64, mediaKind: c.kind == .video ? "video" : "photo", originalTimestamp: c.originalTimestamp, authorName: c.authorName, w: c.media?.width, h: c.media?.height)
        let e = try emit(.contribution, tags: ["moment": c.momentID], payload: s, momentKey: k)
        var out = c; out.id = e.id; out.uploadState = .uploaded; out.createdAt = e.createdAt
        return out
    }

    func removeContribution(id: String, momentID: String) async throws {
        let evs = await store.get([id])
        let owner = await build(momentID)?.creatorID
        guard let e = evs.first, e.author == myID || owner == myID else { throw SocialError.notAllowed }
        try emit(.delete, tags: ["target": id, "moment": momentID], payload: ["reason": "removed"])
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
        if !m.memberIDs.contains(myID) { try emit(.join, tags: ["moment": momentID], payload: Payloads.Join(name: me.displayName), momentKey: keys.load(momentID)); try? await Task.sleep(for: .milliseconds(20)) }
        return try await moment(id: momentID)
    }

    func leaveMoment(id: String) async throws {
        try emit(.leave, tags: ["moment": id], payload: ["left": "1"], momentKey: keys.load(id))
    }

    func merge(sourceID: String, into targetID: String) async throws -> SocialMoment {
        guard let src = await build(sourceID), let dst = await build(targetID), src.creatorID == myID, dst.creatorID == myID else { throw SocialError.notAllowed }
        let sk = keys.load(sourceID), dk = keys.load(targetID)
        for e in await store.forMoment(sourceID) where e.kind == .contribution { if let s = e.payload(Payloads.Side.self, momentKey: sk) { try emit(.contribution, tags: ["moment": targetID, "movedFrom": e.id], payload: s, momentKey: dk) } }
        for (id, name) in zip(src.memberIDs, src.memberNames) where !dst.memberIDs.contains(id) { try emit(.join, tags: ["moment": targetID, "for": id], payload: Payloads.Join(name: name), momentKey: dk) }
        try emit(.delete, tags: ["target": sourceID, "moment": sourceID], payload: ["reason": "merged"])
        try? await Task.sleep(for: .milliseconds(30))
        return try await moment(id: targetID)
    }

    func setCover(momentID: String, data: Data) async throws -> SocialMoment {
        guard let m = await build(momentID), m.creatorID == myID else { throw SocialError.notAllowed }
        try emit(.momentUpdate, tags: ["moment": momentID], payload: Payloads.Update(cover: MediaPipeline.thumbnail(data, side: 720)?.base64EncodedString()), momentKey: keys.load(momentID))
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
            if m.memberIDs.contains(myID) || m.visibility == .publicAll && (following.contains(m.creatorID) || m.isLive) { out.append(m) }
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
        try emit(.claim, tags: ["place": c.placeID], payload: Payloads.Claim(businessName: c.businessName, role: c.role, note: c.note, ownerName: c.ownerName))
        var out = c; out.ownerID = myID; out.verified = false; return out
    }
    func myClaims() async throws -> [PlaceClaim] {
        var out: [PlaceClaim] = []
        for e in await store.all(.claim) where e.author == myID { if let pid = e.tags["place"], let c = try await claim(for: pid), c.ownerID == myID, !out.contains(where: { $0.placeID == pid }) { out.append(c) } }
        return out
    }

    // MARK: - Engagement

    func comments(momentID: String) async throws -> [MomentComment] {
        let k = keys.load(momentID)
        return await store.forMoment(momentID).filter { $0.kind == .comment && !localBlocked.contains($0.author) }.compactMap { e in e.payload(Payloads.Comment.self, momentKey: k).map { MomentComment(id: e.id, momentID: momentID, contributionID: $0.contributionID, authorID: e.author, authorName: $0.authorName, text: $0.text, createdAt: e.createdAt) } }
    }
    func addComment(_ c: MomentComment) async throws -> MomentComment {
        guard ContentModeration.check(c.text) == .ok, let m = await build(c.momentID), canSee(m) else { throw SocialError.notAllowed }
        let e = try emit(.comment, tags: ["moment": c.momentID], payload: Payloads.Comment(text: c.text, contributionID: c.contributionID, authorName: c.authorName), momentKey: keys.load(c.momentID))
        var out = c; out.id = e.id; out.authorID = myID; return out
    }
    func deleteComment(id: String, momentID: String) async throws { try emit(.delete, tags: ["target": id, "moment": momentID], payload: ["reason": "removed"]) }
    func react(momentID: String, contributionID: String?, kind: ReactionKind?) async throws {
        try emit(.reaction, tags: ["moment": momentID], payload: Payloads.Reaction(kind: kind?.rawValue, contributionID: contributionID), momentKey: keys.load(momentID))
    }
    func myReactions(momentID: String) async throws -> [MomentReaction] {
        let k = keys.load(momentID)
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
        let e = try emit(.now, tags: tags, payload: Payloads.Now(text: post.text, media: mediaData.flatMap { MediaPipeline.thumbnail($0, side: 1080) }?.base64EncodedString(), expiresAt: post.expiresAt, coarsePlace: post.coarsePlace, activity: post.activity.rawValue, place: post.place, authorName: post.authorName))
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
    func deleteNow(id: String) async throws { try emit(.delete, tags: ["target": id], payload: ["reason": "removed"]) }
    func joinNow(id: String) async throws -> NowPost {
        let me = try await currentUser()
        try emit(.nowJoin, tags: ["now": id], payload: Payloads.Join(name: me.displayName))
        try? await Task.sleep(for: .milliseconds(20))
        guard let n = try await nowFeed(all: true).first(where: { $0.id == id }) else { throw SocialError.notFound }
        return n
    }

    // MARK: - Graph & safety (follows are public signed events; blocks/mutes stay local)

    func follow(userID: String, close: Bool) async throws { try emit(.follow, tags: ["to": userID, "close": close ? "1" : "0"], payload: ["ok": "1"]); followCache.insert(userID) }
    func unfollow(userID: String) async throws { try emit(.unfollow, tags: ["to": userID], payload: ["ok": "1"]) }
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
    func report(_ report: UserReport) async throws { try emit(.report, tags: [:], payload: Payloads.Report(targetUserID: report.targetUserID, targetMomentID: report.targetMomentID, reason: report.reason.rawValue, details: report.details)) }
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
        for m in await momentsInvolving(myID) where m.templateID == "dm" { out.append(Conversation(id: m.id, participantIDs: m.memberIDs, participantNames: m.memberNames, lastMessage: "", updatedAt: m.createdAt)) }
        return out
    }
    func messages(conversationID: String) async throws -> [DirectMessage] {
        try await comments(momentID: conversationID).map { DirectMessage(id: $0.id, conversationID: conversationID, authorID: $0.authorID, authorName: $0.authorName, text: $0.text, media: nil, momentID: $0.contributionID, createdAt: $0.createdAt) }
    }
    func send(_ message: DirectMessage, mediaData: Data?) async throws -> DirectMessage {
        let c = try await addComment(MomentComment(id: "", momentID: message.conversationID, contributionID: message.momentID, authorID: myID, authorName: message.authorName, text: message.text, createdAt: .now))
        var out = message; out.id = c.id; return out
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
        try emit(.group, tags: ["group": out.id], payload: Payloads.Group(name: out.name, emoji: out.emoji, memberIDs: out.memberIDs, memberNames: out.memberNames, ownerID: myID))
        return out
    }
    func leaveGroup(id: String) async throws {
        guard var g = try await groups().first(where: { $0.id == id }) else { return }
        if g.ownerID == myID { try emit(.group, tags: ["group": id], payload: Payloads.Group(name: g.name, emoji: g.emoji, memberIDs: [], memberNames: [], ownerID: myID)); return }
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

    // MARK: - Sync stats

    func peerCount() -> Int { transports.compactMap { $0 as? MeshTransport }.map(\.peers).reduce(0, +) }
    func relayCount() -> Int { transports.compactMap { $0 as? RelayTransport }.map { $0.connected.count }.reduce(0, +) }
    func eventCount() async -> Int { await store.count }
}
