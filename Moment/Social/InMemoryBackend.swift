import Foundation
import UIKit

#if DEBUG
/// In-process backend for unit tests, the simulator (`-uitest`, `-demo`) and previews.
/// Same contract as CloudKit, no network. All people here are fictional.
actor InMemoryBackend: SocialBackend {
    nonisolated let name = "memory"

    var me: SocialUser
    var users: [String: SocialUser] = [:]
    var moments: [String: SocialMoment] = [:]
    var contributions: [String: [Contribution]] = [:]
    var comments: [String: [MomentComment]] = [:]
    var reactions: [String: [MomentReaction]] = [:]
    var nows: [NowPost] = []
    var follows: [Follow] = []
    var blocked: Set<String> = []
    var muted: Set<String> = []
    var reports: [UserReport] = []
    var safety: SafetySettings {
        get { settingsByUser[me.id] ?? SafetySettings() }
        set { settingsByUser[me.id] = newValue }
    }
    var settingsByUser: [String: SafetySettings] = [:]
    var activityItems: [ActivityItem] = []
    var pendingInvites: [MomentInvite] = []
    var convos: [Conversation] = []
    var dms: [String: [DirectMessage]] = [:]
    var mediaBlobs: [String: Data] = [:]
    var collectionsByID: [String: MomentCollection] = [:]
    var status: AccountStatus = .available
    /// Simulate a dead network for offline-queue tests.
    var offline = false

    init(meID: String = "me", displayName: String = "You") {
        me = SocialUser(id: meID, displayName: displayName, handle: "you", bio: "", avatarRef: nil, isPrivateAccount: false, momentCount: 0, sharedCount: 0, placeCount: 0, peopleCount: 0, createdAt: .now)
        users[meID] = me
    }

    func setOffline(_ v: Bool) { offline = v }
    func setStatus(_ s: AccountStatus) { status = s }
    private func gate() throws { if offline { throw SocialError.offline } }

    // MARK: Identity
    func accountStatus() async -> AccountStatus { status }
    func currentUser() async throws -> SocialUser { try gate(); return me }
    func updateProfile(displayName: String, handle: String, bio: String, avatar: Data?) async throws -> SocialUser {
        try gate()
        me.displayName = displayName; me.handle = handle.lowercased(); me.bio = bio
        if let avatar { mediaBlobs["avatar_me"] = avatar; me.avatarRef = MediaRef(kind: .photo, localRef: nil, remoteID: "avatar_me") }
        users[me.id] = me
        return me
    }
    func user(id: String) async throws -> SocialUser { try gate(); guard let u = users[id] else { throw SocialError.notFound }; return u }
    func searchUsers(_ query: String) async throws -> [SocialUser] {
        try gate()
        let q = query.lowercased().trimmed
        return users.values.filter { $0.id != me.id && !blocked.contains($0.id) && (q.isEmpty || $0.handle.contains(q) || $0.displayName.lowercased().contains(q)) }.sorted { $0.displayName < $1.displayName }
    }

    // MARK: Moments
    func createMoment(_ draft: MomentDraft) async throws -> SocialMoment {
        try gate()
        var cover: MediaRef? = nil
        if let data = draft.coverData { let id = "cover_\(UUID().uuidString)"; mediaBlobs[id] = data; cover = MediaRef(kind: .photo, localRef: nil, remoteID: id) }
        let m = SocialMoment(id: "m_\(UUID().uuidString)", creatorID: me.id, creatorName: me.displayName, title: draft.title, description: draft.description, coverRef: cover, createdAt: .now, startAt: draft.startAt, endAt: draft.endAt, locationName: draft.locationName, coarsePlace: draft.coarsePlace, visibility: draft.visibility, memberIDs: [me.id], memberNames: [me.displayName], contributionCount: 0, mediaCount: 0, commentCount: 0, reactionCounts: [:], shareCount: 0, isLive: draft.isLive, templateID: draft.templateID, remixedFromID: draft.remixedFromID, shareURL: nil, allowsReshare: true, allowsDownload: true, allowsContributions: true)
        moments[m.id] = m
        me.momentCount += 1; users[me.id] = me
        return m
    }
    func updateMoment(_ moment: SocialMoment) async throws -> SocialMoment {
        try gate(); guard var existing = moments[moment.id] else { throw SocialError.notFound }
        guard existing.creatorID == me.id else { throw SocialError.notAllowed }
        existing.title = moment.title; existing.description = moment.description; existing.visibility = moment.visibility
        existing.locationName = moment.locationName; existing.coarsePlace = moment.coarsePlace; existing.isLive = moment.isLive
        existing.allowsReshare = moment.allowsReshare; existing.allowsDownload = moment.allowsDownload; existing.allowsContributions = moment.allowsContributions
        moments[moment.id] = existing
        return existing
    }
    func deleteMoment(id: String) async throws {
        try gate(); guard let m = moments[id] else { throw SocialError.notFound }
        guard m.creatorID == me.id else { throw SocialError.notAllowed }
        moments[id] = nil; contributions[id] = nil; comments[id] = nil; reactions[id] = nil
    }
    func moment(id: String) async throws -> SocialMoment {
        try gate(); guard let m = moments[id] else { throw SocialError.notFound }
        guard canSee(m) else { throw SocialError.notAllowed }
        return m
    }
    private func canSee(_ m: SocialMoment) -> Bool {
        if blocked.contains(m.creatorID) { return false }
        if m.memberIDs.contains(me.id) { return true }
        switch m.visibility {
        case .privateOnly, .group: return false
        case .publicAll: return true
        case .friends: return isFriend(m.creatorID)
        case .closeFriends: return follows.contains { $0.fromID == m.creatorID && $0.toID == me.id && $0.isClose }
        }
    }
    private func isFriend(_ id: String) -> Bool {
        follows.contains { $0.fromID == me.id && $0.toID == id } && follows.contains { $0.fromID == id && $0.toID == me.id }
    }
    func myMoments(cursor: String?) async throws -> FeedPage<SocialMoment> {
        try gate(); return FeedPage(items: moments.values.filter { $0.creatorID == me.id }.sorted { $0.createdAt > $1.createdAt }, cursor: nil)
    }
    func sharedWithMe(cursor: String?) async throws -> FeedPage<SocialMoment> {
        try gate(); return FeedPage(items: moments.values.filter { $0.creatorID != me.id && $0.memberIDs.contains(me.id) }.sorted { $0.createdAt > $1.createdAt }, cursor: nil)
    }
    func contributions(momentID: String) async throws -> [Contribution] { try gate(); _ = try await moment(id: momentID); return contributions[momentID] ?? [] }
    func addContribution(_ c: Contribution, mediaData: Data?) async throws -> Contribution {
        try gate(); guard var m = moments[c.momentID] else { throw SocialError.notFound }
        guard m.allowsContributions, m.memberIDs.contains(me.id) || m.visibility == .publicAll else { throw SocialError.notAllowed }
        var out = c
        if let mediaData { mediaBlobs[c.id] = mediaData; out.media = MediaRef(kind: c.kind == .video ? .video : c.kind == .voice ? .voice : .photo, localRef: c.media?.localRef, remoteID: c.id) }
        out.uploadState = .uploaded
        contributions[c.momentID, default: []].append(out)
        m.contributionCount += 1; if mediaData != nil { m.mediaCount += 1 }
        if !m.memberIDs.contains(c.authorID) { m.memberIDs.append(c.authorID); m.memberNames.append(c.authorName) }
        moments[m.id] = m
        return out
    }
    func removeContribution(id: String, momentID: String) async throws {
        try gate(); guard var m = moments[momentID] else { throw SocialError.notFound }
        guard let c = contributions[momentID]?.first(where: { $0.id == id }) else { throw SocialError.notFound }
        guard c.authorID == me.id || m.creatorID == me.id else { throw SocialError.notAllowed }
        contributions[momentID]?.removeAll { $0.id == id }
        m.contributionCount = max(0, m.contributionCount - 1); moments[momentID] = m
    }
    func share(momentID: String, with userIDs: [String]) async throws -> URL {
        try gate(); guard var m = moments[momentID] else { throw SocialError.notFound }
        guard m.creatorID == me.id else { throw SocialError.notAllowed }
        for id in userIDs where !m.memberIDs.contains(id) {
            guard let u = users[id] else { continue }
            if u.id != me.id, safetyBlocks(u) { continue }
            // Their "who can add me to Moments" setting.
            let their = settingsByUser[id] ?? SafetySettings()
            let mutual = follows.contains { $0.fromID == id && $0.toID == me.id } && follows.contains { $0.fromID == me.id && $0.toID == id }
            if their.whoCanAddMeToMoments == .nobody || (their.whoCanAddMeToMoments == .friends && !mutual) { continue }
            m.memberIDs.append(id); m.memberNames.append(u.displayName)
            pendingInvites.append(MomentInvite(id: "inv_\(UUID().uuidString)", momentID: m.id, momentTitle: m.title, inviterID: me.id, inviterName: me.displayName, shareURL: nil, createdAt: .now, accepted: true))
        }
        let url = m.shareURL ?? URL(string: "https://www.icloud.com/share/\(m.id)#\(m.title.replacingOccurrences(of: " ", with: "_"))")!
        m.shareURL = url; m.shareCount += 1
        moments[m.id] = m
        return url
    }
    private func safetyBlocks(_ u: SocialUser) -> Bool { blocked.contains(u.id) }
    func acceptInvite(url: URL) async throws -> SocialMoment {
        try gate()
        guard let m = moments.values.first(where: { $0.shareURL == url }) else { throw SocialError.notFound }
        var joined = m
        if !joined.memberIDs.contains(me.id) { joined.memberIDs.append(me.id); joined.memberNames.append(me.displayName); moments[m.id] = joined }
        activityItems.insert(ActivityItem(id: "act_\(UUID().uuidString)", kind: .joined, actorName: me.displayName, momentID: m.id, momentTitle: m.title, text: "You joined \(m.title)", createdAt: .now, read: false), at: 0)
        return joined
    }
    func leaveMoment(id: String) async throws {
        try gate(); guard var m = moments[id] else { throw SocialError.notFound }
        guard m.creatorID != me.id else { throw SocialError.notAllowed }
        if let i = m.memberIDs.firstIndex(of: me.id) { m.memberIDs.remove(at: i); if i < m.memberNames.count { m.memberNames.remove(at: i) } }
        moments[id] = m
    }

    func setCover(momentID: String, data: Data) async throws -> SocialMoment {
        try gate(); guard var m = moments[momentID] else { throw SocialError.notFound }
        guard m.creatorID == me.id else { throw SocialError.notAllowed }
        let id = "cover_\(UUID().uuidString)"; mediaBlobs[id] = data
        m.coverRef = MediaRef(kind: .photo, localRef: nil, remoteID: id); moments[momentID] = m
        return m
    }

    // MARK: Feed / discover
    func feed(cursor: String?) async throws -> FeedPage<SocialMoment> {
        try gate()
        let items = moments.values.filter { $0.visibility != .privateOnly || $0.creatorID == me.id }.filter { canSee($0) }.filter { !muted.contains($0.creatorID) }
        return FeedPage(items: items.sorted { $0.createdAt > $1.createdAt }, cursor: nil)
    }
    func discover(query: String?, place: String?, cursor: String?) async throws -> FeedPage<SocialMoment> {
        try gate()
        var items = moments.values.filter { $0.visibility == .publicAll && !blocked.contains($0.creatorID) && !muted.contains($0.creatorID) }
        if let q = query?.lowercased(), !q.isBlank { items = items.filter { $0.title.lowercased().contains(q) || $0.description.lowercased().contains(q) || ($0.coarsePlace?.lowercased().contains(q) ?? false) } }
        if let place, !place.isBlank { items = items.filter { $0.coarsePlace == place } }
        return FeedPage(items: items.sorted { $0.contributionCount > $1.contributionCount }, cursor: nil)
    }

    // MARK: Engagement
    func comments(momentID: String) async throws -> [MomentComment] { try gate(); return (comments[momentID] ?? []).filter { !blocked.contains($0.authorID) } }
    /// The creator's "who can comment" applies to everyone but the creator.
    private func allowed(_ audience: SafetySettings.Audience, by ownerID: String) -> Bool {
        if ownerID == me.id { return true }
        switch audience { case .everyone: return true; case .friends: return isFriend(ownerID); case .nobody: return false }
    }

    func addComment(_ c: MomentComment) async throws -> MomentComment {
        try gate(); guard ContentModeration.check(c.text) == .ok else { throw SocialError.notAllowed }
        guard var m = moments[c.momentID], canSee(m) else { throw SocialError.notFound }
        guard allowed((settingsByUser[m.creatorID] ?? SafetySettings()).whoCanComment, by: m.creatorID) else { throw SocialError.notAllowed }
        comments[c.momentID, default: []].append(c); m.commentCount += 1; moments[m.id] = m
        return c
    }
    func deleteComment(id: String, momentID: String) async throws {
        try gate(); guard let c = comments[momentID]?.first(where: { $0.id == id }) else { throw SocialError.notFound }
        guard c.authorID == me.id || moments[momentID]?.creatorID == me.id else { throw SocialError.notAllowed }
        comments[momentID]?.removeAll { $0.id == id }
        if var m = moments[momentID] { m.commentCount = max(0, m.commentCount - 1); moments[momentID] = m }
    }
    func react(momentID: String, contributionID: String?, kind: ReactionKind?) async throws {
        try gate(); guard var m = moments[momentID] else { throw SocialError.notFound }
        var list = reactions[momentID] ?? []
        if let old = list.first(where: { $0.authorID == me.id && $0.contributionID == contributionID }) {
            list.removeAll { $0.id == old.id }
            adjust(&m, contributionID: contributionID, kind: old.kind, by: -1)
        }
        if let kind {
            list.append(MomentReaction(id: "r_\(UUID().uuidString)", momentID: momentID, contributionID: contributionID, authorID: me.id, kind: kind, createdAt: .now))
            adjust(&m, contributionID: contributionID, kind: kind, by: 1)
        }
        reactions[momentID] = list; moments[momentID] = m
    }
    private func adjust(_ m: inout SocialMoment, contributionID: String?, kind: ReactionKind, by delta: Int) {
        if let cid = contributionID, let i = contributions[m.id]?.firstIndex(where: { $0.id == cid }) {
            contributions[m.id]![i].reactionCounts[kind.rawValue] = max(0, (contributions[m.id]![i].reactionCounts[kind.rawValue] ?? 0) + delta)
        } else {
            m.reactionCounts[kind.rawValue] = max(0, (m.reactionCounts[kind.rawValue] ?? 0) + delta)
        }
    }
    func myReactions(momentID: String) async throws -> [MomentReaction] { try gate(); return (reactions[momentID] ?? []).filter { $0.authorID == me.id } }

    // MARK: NOW
    func postNow(_ post: NowPost, mediaData: Data?) async throws -> NowPost {
        try gate(); guard ContentModeration.check(post.text) == .ok else { throw SocialError.notAllowed }
        var p = post
        if let mediaData { mediaBlobs[p.id] = mediaData; p.media = MediaRef(kind: .photo, localRef: post.media?.localRef, remoteID: p.id) }
        nows.insert(p, at: 0); return p
    }
    func nowFeed() async throws -> [NowPost] {
        try gate()
        let visible = Set(follows.filter { $0.fromID == me.id }.map(\.toID)).union([me.id])
        return nows.filter { !$0.isExpired && visible.contains($0.authorID) && !muted.contains($0.authorID) }
    }
    func deleteNow(id: String) async throws { try gate(); nows.removeAll { $0.id == id && $0.authorID == me.id } }

    // MARK: Graph & safety
    func follow(userID: String, close: Bool) async throws {
        try gate(); guard users[userID] != nil else { throw SocialError.notFound }
        guard !blocked.contains(userID) else { throw SocialError.blocked }
        follows.removeAll { $0.fromID == me.id && $0.toID == userID }
        follows.append(Follow(fromID: me.id, toID: userID, createdAt: .now, isClose: close))
    }
    func unfollow(userID: String) async throws { try gate(); follows.removeAll { $0.fromID == me.id && $0.toID == userID } }
    func following() async throws -> [Follow] { try gate(); return follows.filter { $0.fromID == me.id } }
    func followers() async throws -> [Follow] { try gate(); return follows.filter { $0.toID == me.id } }
    func block(userID: String) async throws {
        try gate(); blocked.insert(userID)
        follows.removeAll { ($0.fromID == me.id && $0.toID == userID) || ($0.fromID == userID && $0.toID == me.id) }
    }
    func unblock(userID: String) async throws { try gate(); blocked.remove(userID) }
    func blockedUserIDs() async throws -> [String] { try gate(); return Array(blocked).sorted() }
    func mute(userID: String) async throws { try gate(); muted.insert(userID) }
    func mutedUserIDs() async throws -> [String] { try gate(); return Array(muted).sorted() }
    func report(_ report: UserReport) async throws { try gate(); reports.append(report) }
    func safetySettings() async throws -> SafetySettings { try gate(); return safety }
    func updateSafetySettings(_ s: SafetySettings) async throws { try gate(); safety = s; me.isPrivateAccount = s.privateAccount; users[me.id] = me }

    // MARK: Inbox
    func activity(cursor: String?) async throws -> FeedPage<ActivityItem> { try gate(); return FeedPage(items: activityItems, cursor: nil) }
    func invites() async throws -> [MomentInvite] { try gate(); return pendingInvites }
    func markActivityRead() async throws { try gate(); activityItems = activityItems.map { var a = $0; a.read = true; return a } }
    func conversations() async throws -> [Conversation] { try gate(); return convos.filter { $0.participantIDs.contains(me.id) }.sorted { $0.updatedAt > $1.updatedAt } }
    func messages(conversationID: String) async throws -> [DirectMessage] { try gate(); return dms[conversationID] ?? [] }
    func send(_ message: DirectMessage, mediaData: Data?) async throws -> DirectMessage {
        try gate(); guard ContentModeration.check(message.text) == .ok else { throw SocialError.notAllowed }
        guard let i = convos.firstIndex(where: { $0.id == message.conversationID }) else { throw SocialError.notFound }
        let other = convos[i].participantIDs.first { $0 != me.id } ?? ""
        guard !blocked.contains(other) else { throw SocialError.blocked }
        var m = message
        if let mediaData { mediaBlobs[m.id] = mediaData; m.media = MediaRef(kind: .photo, localRef: message.media?.localRef, remoteID: m.id) }
        dms[message.conversationID, default: []].append(m)
        convos[i].lastMessage = m.text.isEmpty ? (m.momentID != nil ? "Shared a Moment" : "Photo") : m.text; convos[i].updatedAt = .now
        return m
    }
    func conversation(with userID: String) async throws -> Conversation {
        try gate(); guard let u = users[userID] else { throw SocialError.notFound }
        if let c = convos.first(where: { Set($0.participantIDs) == Set([me.id, userID]) }) { return c }
        if safety.whoCanMessage == .nobody { throw SocialError.notAllowed }
        let c = Conversation(id: "c_\(UUID().uuidString)", participantIDs: [me.id, userID], participantNames: [me.displayName, u.displayName], lastMessage: "", updatedAt: .now)
        convos.append(c); return c
    }

    // MARK: Collections
    func collections() async throws -> [MomentCollection] { try gate(); return collectionsByID.values.filter { $0.ownerID == me.id }.sorted { $0.createdAt < $1.createdAt } }
    func saveCollection(_ c: MomentCollection) async throws -> MomentCollection {
        try gate(); var out = c; out.ownerID = me.id; collectionsByID[c.id] = out; return out
    }
    func deleteCollection(id: String) async throws { try gate(); collectionsByID[id] = nil }

    // MARK: Media
    func download(_ ref: MediaRef) async throws -> Data {
        try gate(); if let id = ref.remoteID, let d = mediaBlobs[id] { return d }
        throw SocialError.notFound
    }

    // MARK: Test helpers

    /// Act as another (fictional) user for a call — lets tests exercise permission checks.
    func acting(as userID: String, _ body: (InMemoryBackend) async throws -> Void) async rethrows {
        let saved = me
        me = users[userID] ?? SocialUser(id: userID, displayName: userID, handle: userID, bio: "", avatarRef: nil, isPrivateAccount: false, momentCount: 0, sharedCount: 0, placeCount: 0, peopleCount: 0, createdAt: .now)
        users[me.id] = me
        defer { me = saved }
        try await body(self)
    }

    func addUser(_ id: String, name: String, handle: String, bio: String = "", isPrivate: Bool = false) {
        users[id] = SocialUser(id: id, displayName: name, handle: handle, bio: bio, avatarRef: nil, isPrivateAccount: isPrivate, momentCount: Int.random(in: 3...30), sharedCount: Int.random(in: 1...12), placeCount: Int.random(in: 2...9), peopleCount: Int.random(in: 3...20), createdAt: .now.adding(days: -200))
    }

    /// Fictional friends and Moments for the simulator and UI tests. Idempotent.
    func seedDemo() {
        guard moments.isEmpty else { return }
        addUser("u_rahul", name: "Rahul Mehta", handle: "rahul", bio: "Goa loyalist. Will not wake up at 7.")
        addUser("u_sarah", name: "Sarah Kim", handle: "sarahk", bio: "Photos of food, mostly.")
        addUser("u_dev", name: "Dev Patel", handle: "devp", bio: "Runs. Talks about running.")
        addUser("u_anaya", name: "Anaya Rao", handle: "anaya", bio: "", isPrivate: true)
        addUser("u_public", name: "Sunset Society", handle: "sunsets", bio: "We chase the last light. Public Moments from the coast.")
        follows = [
            Follow(fromID: me.id, toID: "u_rahul", createdAt: .now.adding(days: -90), isClose: true),
            Follow(fromID: "u_rahul", toID: me.id, createdAt: .now.adding(days: -90), isClose: true),
            Follow(fromID: me.id, toID: "u_sarah", createdAt: .now.adding(days: -60), isClose: false),
            Follow(fromID: "u_sarah", toID: me.id, createdAt: .now.adding(days: -60), isClose: false),
            Follow(fromID: "u_dev", toID: me.id, createdAt: .now.adding(days: -20), isClose: false)
        ]
        func img(_ color: UIColor, _ label: String) -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1200)).image { ctx in
                color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 1200))
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: UIColor.white.withAlphaComponent(0.9)]
                (label as NSString).draw(at: CGPoint(x: 60, y: 1020), withAttributes: attrs)
            }.jpegData(compressionQuality: 0.8)!
        }
        func add(_ id: String, creator: String, title: String, desc: String, daysAgo: Int, members: [String], place: String?, vis: MomentVisibility, color: UIColor, isLive: Bool = false, contribs: [(String, Contribution.Kind, String, Int)]) {
            let creatorUser = users[creator]!
            mediaBlobs["cover_\(id)"] = img(color, title)
            var m = SocialMoment(id: id, creatorID: creator, creatorName: creatorUser.displayName, title: title, description: desc, coverRef: MediaRef(kind: .photo, localRef: nil, remoteID: "cover_\(id)"), createdAt: .now.adding(days: -daysAgo), startAt: .now.adding(days: -daysAgo), endAt: nil, locationName: place, coarsePlace: place, visibility: vis, memberIDs: members, memberNames: members.map { users[$0]?.displayName ?? $0 }, contributionCount: 0, mediaCount: 0, commentCount: 0, reactionCounts: [:], shareCount: members.count, isLive: isLive, templateID: nil, remixedFromID: nil, shareURL: URL(string: "https://www.icloud.com/share/\(id)"), allowsReshare: true, allowsDownload: true, allowsContributions: true)
            var list: [Contribution] = []
            for (i, c) in contribs.enumerated() {
                let cid = "c_\(id)_\(i)"
                var ref: MediaRef? = nil
                if c.1 != .text { mediaBlobs[cid] = img(color.withAlphaComponent(0.7 + Double(i % 3) * 0.1), c.2); ref = MediaRef(kind: .photo, localRef: nil, remoteID: cid) }
                list.append(Contribution(id: cid, momentID: id, authorID: c.0, authorName: users[c.0]?.displayName ?? c.0, kind: c.1, media: ref, caption: c.2, createdAt: .now.adding(days: -daysAgo).addingTimeInterval(Double(c.3) * 60), originalTimestamp: .now.adding(days: -daysAgo).addingTimeInterval(Double(c.3) * 60), reactionCounts: i == 0 ? ["core": 3, "forgot": 1] : [:], commentCount: 0, uploadState: .uploaded))
            }
            m.contributionCount = list.count; m.mediaCount = list.filter { $0.media != nil }.count
            m.reactionCounts = ["core": 4, "unreal": 2]
            contributions[id] = list
            moments[id] = m
        }
        add("m_goa", creator: me.id, title: "Goa '26", desc: "Three days. Zero 7am wake-ups.", daysAgo: 9, members: [me.id, "u_rahul", "u_sarah"], place: "Goa", vis: .group, color: UIColor(red: 0.95, green: 0.55, blue: 0.25, alpha: 1), contribs: [
            (me.id, .photo, "Palolem at 6", 0), ("u_rahul", .photo, "Told you", 40), ("u_sarah", .photo, "Fish thali", 180), ("u_rahul", .text, "we're waking up at 7 tomorrow 😂", 600), ("u_sarah", .photo, "Last night", 1400)
        ])
        add("m_bday", creator: "u_rahul", title: "Sarah's 30th", desc: "", daysAgo: 2, members: ["u_rahul", "u_sarah", me.id, "u_dev"], place: "Bandra", vis: .group, color: UIColor(red: 0.45, green: 0.3, blue: 0.85, alpha: 1), contribs: [
            ("u_rahul", .photo, "Cake situation", 0), ("u_dev", .photo, "Speech", 25), ("u_sarah", .photo, "Everyone", 90)
        ])
        add("m_run", creator: "u_dev", title: "Sunday long run", desc: "21k, no walking.", daysAgo: 1, members: ["u_dev"], place: "Marine Drive", vis: .publicAll, color: UIColor(red: 0.2, green: 0.6, blue: 0.5, alpha: 1), contribs: [("u_dev", .photo, "Km 18", 0), ("u_dev", .photo, "Done", 70)])
        add("m_sunset", creator: "u_public", title: "Last light, Versova", desc: "Every Friday. Bring nothing.", daysAgo: 0, members: ["u_public"], place: "Versova", vis: .publicAll, color: UIColor(red: 0.9, green: 0.35, blue: 0.4, alpha: 1), isLive: true, contribs: [("u_public", .photo, "6:41pm", 0), ("u_public", .photo, "6:52pm", 11), ("u_public", .photo, "7:03pm", 22)])
        add("m_oldgoa", creator: me.id, title: "Goa '25", desc: "The first one.", daysAgo: 365, members: [me.id, "u_rahul"], place: "Goa", vis: .group, color: UIColor(red: 0.2, green: 0.45, blue: 0.8, alpha: 1), contribs: [(me.id, .photo, "Anjuna", 0), ("u_rahul", .photo, "Same beach", 30)])
        comments["m_goa"] = [MomentComment(id: "cm1", momentID: "m_goa", contributionID: nil, authorID: "u_rahul", authorName: "Rahul Mehta", text: "We are going back.", createdAt: .now.adding(days: -8)), MomentComment(id: "cm2", momentID: "m_goa", contributionID: nil, authorID: "u_sarah", authorName: "Sarah Kim", text: "The thali though 🫶", createdAt: .now.adding(days: -8))]
        moments["m_goa"]!.commentCount = 2
        nows = [
            NowPost(id: "n1", authorID: "u_rahul", authorName: "Rahul Mehta", text: "Chai run. Who's up", media: nil, createdAt: .now.addingTimeInterval(-1800), expiresAt: .now.addingTimeInterval(22 * 3600), coarsePlace: "Bandra", savedToMomentID: nil),
            NowPost(id: "n2", authorID: "u_sarah", authorName: "Sarah Kim", text: "Finally trying that ramen place", media: nil, createdAt: .now.addingTimeInterval(-5400), expiresAt: .now.addingTimeInterval(18 * 3600), coarsePlace: "Lower Parel", savedToMomentID: nil)
        ]
        activityItems = [
            ActivityItem(id: "a1", kind: .contribution, actorName: "Rahul Mehta", momentID: "m_bday", momentTitle: "Sarah's 30th", text: "Rahul added 3 photos to Sarah's 30th", createdAt: .now.addingTimeInterval(-3600), read: false),
            ActivityItem(id: "a2", kind: .reaction, actorName: "Sarah Kim", momentID: "m_goa", momentTitle: "Goa '26", text: "Sarah reacted ❤️ to Goa '26", createdAt: .now.addingTimeInterval(-7200), read: false),
            ActivityItem(id: "a3", kind: .follow, actorName: "Dev Patel", momentID: nil, momentTitle: nil, text: "Dev started following you", createdAt: .now.adding(days: -1), read: true)
        ]
        pendingInvites = [MomentInvite(id: "inv1", momentID: "m_bday", momentTitle: "Sarah's 30th", inviterID: "u_rahul", inviterName: "Rahul Mehta", shareURL: URL(string: "https://www.icloud.com/share/m_bday"), createdAt: .now.adding(days: -2), accepted: true)]
        convos = [Conversation(id: "conv_rahul", participantIDs: [me.id, "u_rahul"], participantNames: [me.displayName, "Rahul Mehta"], lastMessage: "send me the thali one", updatedAt: .now.addingTimeInterval(-600))]
        dms["conv_rahul"] = [
            DirectMessage(id: "d1", conversationID: "conv_rahul", authorID: "u_rahul", authorName: "Rahul Mehta", text: "this one", media: nil, momentID: "m_goa", createdAt: .now.addingTimeInterval(-900)),
            DirectMessage(id: "d2", conversationID: "conv_rahul", authorID: "u_rahul", authorName: "Rahul Mehta", text: "send me the thali one", media: nil, momentID: nil, createdAt: .now.addingTimeInterval(-600))
        ]
        me.momentCount = 2; me.sharedCount = 3; me.placeCount = 3; me.peopleCount = 4; users[me.id] = me
    }
}
#endif
