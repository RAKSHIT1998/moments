import Foundation
import SwiftUI
import UserNotifications

/// The one object the UI talks to for anything social. Wraps the backend, the offline queue and
/// a small in-memory cache so screens render instantly and refresh in the background.
@MainActor
@Observable
final class SocialService {
    let backend: any SocialBackend
    let queue: UploadQueue
    private let media: MediaStore
    private let settings: SettingsStore
    private let analytics: AnalyticsService

    // Session
    private(set) var accountStatus: AccountStatus = .unknown
    private(set) var me: SocialUser?
    var lastError: String?
    var isSignedIn: Bool { accountStatus == .available && me != nil }

    // Feed
    private(set) var feed: [FeedRanker.Scored] = []
    private(set) var nowPosts: [NowPost] = []
    private(set) var isLoadingFeed = false
    private(set) var graph = RelationshipGraph()
    private var seen: Set<String> = []

    // Caches
    private(set) var moments: [String: SocialMoment] = [:]
    private(set) var contributions: [String: [Contribution]] = [:]
    private(set) var comments: [String: [MomentComment]] = [:]
    private(set) var myReactions: [String: [MomentReaction]] = [:]
    private(set) var users: [String: SocialUser] = [:]
    private(set) var activity: [ActivityItem] = []
    private(set) var invites: [MomentInvite] = []
    private(set) var conversations: [Conversation] = []
    private(set) var messages: [String: [DirectMessage]] = [:]
    private(set) var blocked: Set<String> = []
    private(set) var muted: Set<String> = []
    private(set) var safety = SafetySettings()
    private var imageCache: [String: UIImage] = [:]
    private var lastContributionCounts: [String: Int] = [:]

    /// Navigation targets set by deep links / notifications.
    var pendingMomentID: String?
    var pendingInviteError: String?
    var pendingConversationID: String?
    /// Pre-filled input when remixing someone's Moment.
    var remixDraft: NewMomentInput?
    var unreadActivity: Int { activity.filter { !$0.read }.count }

    init(backend: any SocialBackend, media: MediaStore, settings: SettingsStore, analytics: AnalyticsService, queueDirectory: URL? = nil) {
        self.backend = backend
        self.media = media
        self.settings = settings
        self.analytics = analytics
        self.queue = UploadQueue(backend: backend, media: media, directory: queueDirectory)
        queue.onUploaded = { [weak self] job in
            guard let self else { return }
            Task {
                switch job {
                case .contribution(let c): await self.loadMoment(c.momentID)
                case .now: await self.refreshNow()
                }
            }
        }
    }

    var displayName: String { me?.displayName ?? (settings.displayName.isBlank ? "You" : settings.displayName) }
    var myID: String { me?.id ?? "" }

    // MARK: - Session

    func start() async {
        accountStatus = await backend.accountStatus()
        guard accountStatus == .available else { return }
        do {
            me = try await backend.currentUser()
            if let me, !settings.displayName.isBlank, me.displayName == "You" {
                self.me = try? await backend.updateProfile(displayName: settings.displayName, handle: me.handle, bio: me.bio, avatar: nil)
            }
            if let ck = backend as? CloudKitBackend { Task { await ck.ensureSubscriptions() } }
            await refreshAll()
            queue.drain()
        } catch { lastError = error.localizedDescription }
    }

    func refreshAll() async {
        async let f: () = refreshFeed()
        async let n: () = refreshNow()
        async let i: () = refreshInbox()
        async let s: () = refreshSafety()
        _ = await (f, n, i, s)
    }

    func updateProfile(displayName: String, handle: String, bio: String, avatar: Data?) async -> Bool {
        do {
            me = try await backend.updateProfile(displayName: displayName, handle: handle, bio: bio, avatar: avatar)
            settings.displayName = displayName
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    // MARK: - Feed

    func refreshFeed() async {
        isLoadingFeed = true
        defer { isLoadingFeed = false }
        do {
            let page = try await backend.feed(cursor: nil)
            for m in page.items { moments[m.id] = m }
            await rebuildGraph(from: page.items)
            feed = FeedRanker.rank(page.items, me: myID, graph: graph, seen: seen)
            detectNewContributions(page.items)
        } catch { lastError = error.localizedDescription }
    }

    private func rebuildGraph(from items: [SocialMoment]) async {
        var g = RelationshipGraph()
        for m in items where m.memberIDs.contains(myID) {
            for id in m.memberIDs where id != myID { g.sharedMomentCounts[id, default: 0] += 1 }
        }
        if let f = try? await backend.following() { g.following = Set(f.map(\.toID)); g.close = Set(f.filter(\.isClose).map(\.toID)) }
        if let f = try? await backend.followers() { g.followers = Set(f.map(\.fromID)) }
        g.blocked = blocked; g.muted = muted
        graph = g
    }

    func markSeen(_ id: String) { seen.insert(id) }

    /// "One year ago" — Moments you were part of on this day in a previous year.
    var onThisDay: [SocialMoment] {
        let cal = Calendar.current
        let today = cal.dateComponents([.month, .day], from: .now)
        return moments.values.filter { m in
            guard m.memberIDs.contains(myID) else { return false }
            let d = m.startAt ?? m.createdAt
            let c = cal.dateComponents([.month, .day, .year], from: d)
            return c.month == today.month && c.day == today.day && c.year != cal.component(.year, from: .now)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    var myMoments: [SocialMoment] { moments.values.filter { $0.creatorID == myID }.sorted { $0.createdAt > $1.createdAt } }
    var momentsImIn: [SocialMoment] { moments.values.filter { $0.memberIDs.contains(myID) }.sorted { $0.createdAt > $1.createdAt } }

    /// Moments shared with a specific person.
    func moments(with userID: String) -> [SocialMoment] {
        moments.values.filter { $0.memberIDs.contains(userID) && $0.memberIDs.contains(myID) }.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Moment

    @discardableResult
    func loadMoment(_ id: String) async -> SocialMoment? {
        do {
            let m = try await backend.moment(id: id)
            moments[id] = m
            contributions[id] = try await backend.contributions(momentID: id)
            comments[id] = (try? await backend.comments(momentID: id)) ?? []
            myReactions[id] = (try? await backend.myReactions(momentID: id)) ?? []
            return m
        } catch {
            lastError = error.localizedDescription
            return moments[id]
        }
    }

    /// Contributions including the ones still uploading from this device.
    func allContributions(_ momentID: String) -> [Contribution] {
        let uploaded = contributions[momentID] ?? []
        let pending = queue.entries.compactMap { e -> Contribution? in
            if case .contribution(let c) = e.job, c.momentID == momentID, !uploaded.contains(where: { $0.id == c.id }) {
                var p = c; p.uploadState = e.attempts >= UploadQueue.maxAttempts ? .failed : (queue.isDraining ? .uploading : .pending); return p
            }
            return nil
        }
        return uploaded + pending
    }

    struct NewMomentInput {
        var title: String
        var description: String = ""
        var startAt: Date? = nil
        var endAt: Date? = nil
        var locationName: String? = nil
        var visibility: MomentVisibility = .group
        var templateID: String? = nil
        var remixedFromID: String? = nil
        var isLive = false
        var photos: [Data] = []
        var videoURLs: [URL] = []
        var note: String = ""
    }

    /// Creates the Moment right away (needs network) and queues the media, so a 40-photo Moment
    /// exists in a second and fills in as uploads land.
    func createMoment(_ input: NewMomentInput) async -> SocialMoment? {
        guard let me else { lastError = SocialError.notSignedIn.localizedDescription; return nil }
        let prepared = input.photos.compactMap(MediaPipeline.preparePhoto)
        let dates = prepared.compactMap(\.capturedAt).sorted()
        let draft = MomentDraft(title: input.title.isBlank ? "Untitled Moment" : input.title.trimmed, description: input.description.trimmed, startAt: input.startAt ?? dates.first, endAt: input.endAt ?? (dates.count > 1 ? dates.last : nil), locationName: input.locationName, coarsePlace: input.locationName.map(Self.coarse), visibility: input.visibility, templateID: input.templateID, remixedFromID: input.remixedFromID, isLive: input.isLive, coverData: prepared.first.flatMap { MediaPipeline.thumbnail($0.data, side: 1080) })
        do {
            let m = try await backend.createMoment(draft)
            moments[m.id] = m
            if analytics.count(.momentCreated) == 0 { analytics.track(.firstMomentCreated) }
            analytics.track(.momentCreated, category: input.visibility.rawValue)
            await enqueue(prepared: prepared, videos: input.videoURLs, note: input.note, momentID: m.id, author: me)
            if input.remixedFromID != nil { analytics.track(.momentRemixed) }
            return m
        } catch { lastError = error.localizedDescription; return nil }
    }

    /// ADD YOUR SIDE: photos, a video, a note — attributed to you, in the same Moment.
    func addSide(momentID: String, photos: [Data], videoURLs: [URL] = [], note: String) async {
        guard let me else { return }
        let prepared = photos.compactMap(MediaPipeline.preparePhoto)
        await enqueue(prepared: prepared, videos: videoURLs, note: note, momentID: momentID, author: me)
        analytics.track(.sideAdded)
    }

    private func enqueue(prepared: [MediaPipeline.Prepared], videos: [URL], note: String, momentID: String, author: SocialUser) async {
        for p in prepared {
            guard let local = try? await media.store(p.data, extension: p.fileExtension) else { continue }
            let c = Contribution(id: UUID().uuidString, momentID: momentID, authorID: author.id, authorName: author.displayName, kind: .photo, media: MediaRef(kind: .photo, localRef: local, remoteID: nil, width: p.width, height: p.height), caption: "", createdAt: .now, originalTimestamp: p.capturedAt, reactionCounts: [:], commentCount: 0, uploadState: .pending)
            queue.enqueue(.contribution(c))
        }
        for url in videos {
            guard let p = try? await MediaPipeline.prepareVideo(at: url), let local = try? await media.store(p.data, extension: "mp4") else { continue }
            let c = Contribution(id: UUID().uuidString, momentID: momentID, authorID: author.id, authorName: author.displayName, kind: .video, media: MediaRef(kind: .video, localRef: local, remoteID: nil, width: p.width, height: p.height, durationSeconds: p.duration), caption: "", createdAt: .now, originalTimestamp: p.capturedAt, reactionCounts: [:], commentCount: 0, uploadState: .pending)
            queue.enqueue(.contribution(c))
        }
        if !note.isBlank {
            let c = Contribution(id: UUID().uuidString, momentID: momentID, authorID: author.id, authorName: author.displayName, kind: .text, media: nil, caption: note.trimmed, createdAt: .now, originalTimestamp: nil, reactionCounts: [:], commentCount: 0, uploadState: .pending)
            queue.enqueue(.contribution(c))
        }
    }

    func update(_ m: SocialMoment) async -> Bool {
        do { moments[m.id] = try await backend.updateMoment(m); return true } catch { lastError = error.localizedDescription; return false }
    }

    func delete(momentID: String) async -> Bool {
        do {
            try await backend.deleteMoment(id: momentID)
            moments[momentID] = nil; contributions[momentID] = nil
            feed.removeAll { $0.moment.id == momentID }
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    func removeContribution(_ c: Contribution) async {
        if queue.isPending(c.id) { queue.remove(id: c.id); return }
        do { try await backend.removeContribution(id: c.id, momentID: c.momentID); await loadMoment(c.momentID) } catch { lastError = error.localizedDescription }
    }

    func leave(momentID: String) async -> Bool {
        do { try await backend.leaveMoment(id: momentID); moments[momentID] = nil; feed.removeAll { $0.moment.id == momentID }; return true } catch { lastError = error.localizedDescription; return false }
    }

    // MARK: - Invites (the viral loop)

    /// Real share link. Members added here can open it straight away.
    func shareLink(momentID: String, with userIDs: [String] = []) async -> URL? {
        do {
            let url = try await backend.share(momentID: momentID, with: userIDs)
            let wasShared = (moments[momentID]?.memberIDs.count ?? 1) > 1
            if var m = moments[momentID] { m.shareURL = url; m.shareCount += 1; moments[momentID] = m }
            analytics.track(.momentShared, category: userIDs.isEmpty ? "link" : "direct")
            if !userIDs.isEmpty { analytics.track(.inviteSent); if !wasShared { analytics.track(.sharedMomentCreated) } }
            await loadMoment(momentID)
            return url
        } catch { lastError = error.localizedDescription; return nil }
    }

    static func isInviteURL(_ url: URL) -> Bool {
        (url.host()?.hasSuffix("icloud.com") ?? false) && url.path().contains("/share/")
    }

    /// Opened from Messages/AirDrop/Safari. Joins and navigates.
    func acceptInvite(_ url: URL) async {
        do {
            let m = try await backend.acceptInvite(url: url)
            moments[m.id] = m
            analytics.track(.sharedMomentOpened)
            analytics.track(.contextualInviteAccepted)
            analytics.track(.momentJoined)
            pendingMomentID = m.id
            await refreshFeed()
        } catch { pendingInviteError = error.localizedDescription }
    }

    // MARK: - Engagement

    func react(momentID: String, contributionID: String? = nil, kind: ReactionKind) async {
        let mine = myReactions[momentID]?.first { $0.contributionID == contributionID }
        let next: ReactionKind? = mine?.kind == kind ? nil : kind
        // Optimistic
        var list = myReactions[momentID] ?? []
        list.removeAll { $0.contributionID == contributionID }
        if let next { list.append(MomentReaction(id: UUID().uuidString, momentID: momentID, contributionID: contributionID, authorID: myID, kind: next, createdAt: .now)) }
        myReactions[momentID] = list
        do {
            try await backend.react(momentID: momentID, contributionID: contributionID, kind: next)
            if next != nil { analytics.track(.reactionAdded, category: kind.rawValue) }
            await loadMoment(momentID)
        } catch { lastError = error.localizedDescription }
    }

    func myReaction(momentID: String, contributionID: String? = nil) -> ReactionKind? {
        myReactions[momentID]?.first { $0.contributionID == contributionID }?.kind
    }

    func comment(momentID: String, contributionID: String? = nil, text: String) async -> Bool {
        guard let me else { return false }
        switch ContentModeration.check(text) {
        case .blocked(let why): lastError = why; return false
        case .spam: lastError = "That looks like spam."; return false
        case .ok: break
        }
        let c = MomentComment(id: UUID().uuidString, momentID: momentID, contributionID: contributionID, authorID: me.id, authorName: me.displayName, text: text.trimmed, createdAt: .now)
        do {
            let saved = try await backend.addComment(c)
            comments[momentID, default: []].append(saved)
            if var m = moments[momentID] { m.commentCount += 1; moments[momentID] = m }
            analytics.track(.commentAdded)
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    func deleteComment(_ c: MomentComment) async {
        do { try await backend.deleteComment(id: c.id, momentID: c.momentID); comments[c.momentID]?.removeAll { $0.id == c.id } } catch { lastError = error.localizedDescription }
    }

    // MARK: - NOW

    func refreshNow() async {
        if let posts = try? await backend.nowFeed() { nowPosts = posts.filter { !muted.contains($0.authorID) && !blocked.contains($0.authorID) } }
    }

    func postNow(text: String, photo: Data?, place: String?) async -> Bool {
        guard let me else { return false }
        if case .blocked(let why) = ContentModeration.check(text) { lastError = why; return false }
        var ref: MediaRef? = nil
        if let photo, let p = MediaPipeline.preparePhoto(photo), let local = try? await media.store(p.data, extension: "jpg") { ref = MediaRef(kind: .photo, localRef: local, remoteID: nil, width: p.width, height: p.height) }
        let post = NowPost(id: UUID().uuidString, authorID: me.id, authorName: me.displayName, text: text.trimmed, media: ref, createdAt: .now, expiresAt: .now.addingTimeInterval(24 * 3600), coarsePlace: place.map(Self.coarse), savedToMomentID: nil)
        nowPosts.insert(post, at: 0)
        queue.enqueue(.now(post))
        analytics.track(.nowPosted, category: photo == nil ? "text" : "photo")
        return true
    }

    /// NOW is ephemeral unless you keep it: this turns a post into a contribution on a Moment.
    func saveNow(_ post: NowPost, to momentID: String) async {
        guard let me else { return }
        let c = Contribution(id: UUID().uuidString, momentID: momentID, authorID: me.id, authorName: me.displayName, kind: post.media == nil ? .text : .photo, media: post.media, caption: post.text, createdAt: .now, originalTimestamp: post.createdAt, reactionCounts: [:], commentCount: 0, uploadState: .pending)
        queue.enqueue(.contribution(c))
        if let i = nowPosts.firstIndex(where: { $0.id == post.id }) { nowPosts[i].savedToMomentID = momentID }
        analytics.track(.nowSaved)
    }

    func deleteNow(_ post: NowPost) async {
        nowPosts.removeAll { $0.id == post.id }
        queue.remove(id: post.id)
        try? await backend.deleteNow(id: post.id)
    }

    // MARK: - People

    func user(_ id: String) async -> SocialUser? {
        if let u = users[id] { return u }
        if let u = try? await backend.user(id: id) { users[id] = u; return u }
        return nil
    }

    func search(people query: String) async -> [SocialUser] {
        let r = (try? await backend.searchUsers(query)) ?? []
        for u in r { users[u.id] = u }
        return r.filter { !blocked.contains($0.id) }
    }

    func isFollowing(_ id: String) -> Bool { graph.following.contains(id) }
    func isClose(_ id: String) -> Bool { graph.close.contains(id) }
    func isFriend(_ id: String) -> Bool { graph.following.contains(id) && graph.followers.contains(id) }

    func follow(_ id: String, close: Bool = false) async {
        do { try await backend.follow(userID: id, close: close); graph.following.insert(id); if close { graph.close.insert(id) } else { graph.close.remove(id) } } catch { lastError = error.localizedDescription }
    }
    func unfollow(_ id: String) async {
        do { try await backend.unfollow(userID: id); graph.following.remove(id); graph.close.remove(id) } catch { lastError = error.localizedDescription }
    }

    func discover(query: String?, place: String?) async -> [SocialMoment] {
        let page = (try? await backend.discover(query: query, place: place, cursor: nil))?.items ?? []
        for m in page { moments[m.id] = m }
        return page.filter { !blocked.contains($0.creatorID) && !muted.contains($0.creatorID) }
    }

    // MARK: - Safety

    func refreshSafety() async {
        blocked = Set((try? await backend.blockedUserIDs()) ?? [])
        muted = Set((try? await backend.mutedUserIDs()) ?? [])
        safety = (try? await backend.safetySettings()) ?? SafetySettings()
        graph.blocked = blocked; graph.muted = muted
    }

    func block(_ id: String) async {
        do {
            try await backend.block(userID: id); blocked.insert(id); graph.blocked = blocked
            analytics.track(.userBlocked)
            feed.removeAll { $0.moment.creatorID == id }
            nowPosts.removeAll { $0.authorID == id }
        } catch { lastError = error.localizedDescription }
    }
    func unblock(_ id: String) async { do { try await backend.unblock(userID: id); blocked.remove(id); graph.blocked = blocked } catch { lastError = error.localizedDescription } }
    func mute(_ id: String) async { do { try await backend.mute(userID: id); muted.insert(id); graph.muted = muted; feed.removeAll { $0.moment.creatorID == id } } catch { lastError = error.localizedDescription } }
    func report(userID: String? = nil, momentID: String? = nil, contributionID: String? = nil, commentID: String? = nil, reason: UserReport.Reason, details: String) async -> Bool {
        do {
            try await backend.report(UserReport(id: UUID().uuidString, reporterID: myID, targetUserID: userID, targetMomentID: momentID, targetContributionID: contributionID, targetCommentID: commentID, reason: reason, details: details, createdAt: .now))
            analytics.track(.reportSent, category: reason.rawValue)
            return true
        } catch { lastError = error.localizedDescription; return false }
    }
    func updateSafety(_ s: SafetySettings) async {
        safety = s
        do { try await backend.updateSafetySettings(s); if var me { me.isPrivateAccount = s.privateAccount; self.me = me } } catch { lastError = error.localizedDescription }
    }

    // MARK: - Inbox

    func refreshInbox() async {
        if let a = try? await backend.activity(cursor: nil) { activity = a.items }
        invites = (try? await backend.invites()) ?? []
        conversations = (try? await backend.conversations()) ?? []
    }

    func markActivityRead() async { activity = activity.map { var a = $0; a.read = true; return a }; try? await backend.markActivityRead() }

    func loadMessages(_ conversationID: String) async { messages[conversationID] = (try? await backend.messages(conversationID: conversationID)) ?? [] }

    func conversation(with userID: String) async -> Conversation? {
        do { let c = try await backend.conversation(with: userID); if !conversations.contains(where: { $0.id == c.id }) { conversations.insert(c, at: 0) }; return c } catch { lastError = error.localizedDescription; return nil }
    }

    func send(conversationID: String, text: String, momentID: String? = nil, photo: Data? = nil) async -> Bool {
        guard let me else { return false }
        if case .blocked(let why) = ContentModeration.check(text) { lastError = why; return false }
        var ref: MediaRef? = nil
        var data: Data? = nil
        if let photo, let p = MediaPipeline.preparePhoto(photo), let local = try? await media.store(p.data, extension: "jpg") { ref = MediaRef(kind: .photo, localRef: local, remoteID: nil); data = p.data }
        let m = DirectMessage(id: UUID().uuidString, conversationID: conversationID, authorID: me.id, authorName: me.displayName, text: text.trimmed, media: ref, momentID: momentID, createdAt: .now)
        do {
            let saved = try await backend.send(m, mediaData: data)
            messages[conversationID, default: []].append(saved)
            if let i = conversations.firstIndex(where: { $0.id == conversationID }) { conversations[i].lastMessage = saved.text.isEmpty ? "Shared a Moment" : saved.text; conversations[i].updatedAt = .now }
            analytics.track(.messageSent, category: momentID == nil ? "text" : "moment")
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    // MARK: - Media

    func image(for ref: MediaRef?) async -> UIImage? {
        guard let ref else { return nil }
        let key = ref.remoteID ?? ref.localRef ?? ""
        if let cached = imageCache[key] { return cached }
        var image: UIImage? = nil
        if let local = ref.localRef { image = await media.loadImage(local) }
        if image == nil, let data = try? await backend.download(ref) { image = UIImage(data: data) }
        if let image { imageCache[key] = image }
        return image
    }

    func videoURL(for ref: MediaRef) async -> URL? {
        if let local = ref.localRef, let url = try? await media.temporaryURL(for: local, extension: "mp4") { return url }
        guard let data = try? await backend.download(ref) else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "\(ref.remoteID ?? UUID().uuidString).mp4")
        try? data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Notifications ("Rahul added 8 photos")

    /// Called from a CloudKit push (or a foreground refresh). Compares contribution counts and
    /// posts one local notification per Moment that grew — never content, just who and how many.
    func handleRemoteChange() async {
        await refreshFeed()
        await refreshInbox()
    }

    private func detectNewContributions(_ items: [SocialMoment]) {
        for m in items where m.memberIDs.contains(myID) {
            if let old = lastContributionCounts[m.id], m.contributionCount > old, m.creatorID != myID || m.memberIDs.count > 1 {
                let content = UNMutableNotificationContent()
                content.title = m.title
                content.body = "\(m.contributionCount - old) new \(m.contributionCount - old == 1 ? "addition" : "additions") from people who were there"
                content.userInfo = ["momentID": m.id]
                content.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "moment.\(m.id).\(m.contributionCount)", content: content, trigger: nil))
            }
            lastContributionCounts[m.id] = m.contributionCount
        }
    }

    static func coarse(_ place: String) -> String {
        // City-level only: keep the last meaningful component ("Palolem Beach, Goa" → "Goa").
        let parts = place.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
        return parts.last ?? place.trimmed
    }
}
