import Foundation
import SwiftUI
import UserNotifications

/// The one object the UI talks to for anything social. Wraps the backend, the offline queue and
/// a small in-memory cache so screens render instantly and refresh in the background.
@MainActor
@Observable
final class SocialService {
    private(set) var backend: any SocialBackend
    private(set) var queue: UploadQueue
    private let media: MediaStore
    private let settings: SettingsStore
    private let analytics: AnalyticsService
    var subscriptions: SubscriptionService = SubscriptionService()

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
    private(set) var collections: [MomentCollection] = []
    private(set) var groups: [SocialGroup] = []
    // Nearby (from the device's one-shot location; never uploaded)
    private(set) var nearbyMoments: [SocialMoment] = []
    private(set) var nearbyNow: [NowPost] = []
    private(set) var placeMoments: [String: [SocialMoment]] = [:]
    private(set) var claims: [String: PlaceClaim] = [:]
    private(set) var myClaims: [PlaceClaim] = []
    var nearbyRadiusKm: Double = 3
    private(set) var hasLoadedOnce = false
    private var imageCache: [String: UIImage] = [:]
    private var lastContributionCounts: [String: Int] = [:]

    /// Navigation targets set by deep links / notifications.
    var pendingMomentID: String?
    var pendingInviteError: String?
    var pendingNowID: String?
    /// Pre-filled input when remixing someone's Moment.
    var remixDraft: NewMomentInput?
    var unreadActivity: Int { activity.filter { !$0.read }.count }

    init(backend: any SocialBackend, media: MediaStore, settings: SettingsStore, analytics: AnalyticsService, queueDirectory: URL? = nil) {
        self.backend = backend
        self.media = media
        self.settings = settings
        self.analytics = analytics
        self.queueDirectory = queueDirectory
        self.queue = UploadQueue(backend: backend, media: media, directory: queueDirectory)
        wireQueue()
    }

    private let queueDirectory: URL?

    private func wireQueue() {
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

    /// DEBUG demo mode swaps the backend at runtime; all caches are dropped.
    func replaceBackend(_ new: any SocialBackend) {
        backend = new
        queue = UploadQueue(backend: new, media: media, directory: queueDirectory)
        wireQueue()
        me = nil; feed = []; nowPosts = []; moments = [:]; contributions = [:]; comments = [:]; myReactions = [:]; users = [:]
        activity = []; invites = []; conversations = []; messages = [:]; collections = []; groups = []; imageCache = [:]; seen = []
        hasLoadedOnce = false
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
        async let c: () = refreshCollections()
        async let g: () = refreshGroups()
        _ = await (f, n, i, s, c, g)
        hasLoadedOnce = true
    }

    // MARK: - Nearby & places

    /// Refreshes what's happening around a coordinate. Distance is computed client-side for display.
    func refreshNearby(latitude: Double, longitude: Double) async {
        async let m = backend.nearby(latitude: latitude, longitude: longitude, radiusKm: nearbyRadiusKm)
        async let n = backend.nowNearby(latitude: latitude, longitude: longitude, radiusKm: nearbyRadiusKm)
        let moms = (try? await m) ?? [], nows = (try? await n) ?? []
        for x in moms { moments[x.id] = x }
        nearbyMoments = moms.filter { !blocked.contains($0.creatorID) && !muted.contains($0.creatorID) }
        nearbyNow = nows.filter { !blocked.contains($0.authorID) && !muted.contains($0.authorID) }
        notifyFriendsNearby()
    }

    private var notifiedNearby: Set<String> = []
    /// "Rahul is at Bastian, 400 m away" — friends only, once per post, only if the user allowed it.
    private func notifyFriendsNearby() {
        guard settings.socialNotifications else { return }
        for n in nearbyNow where n.authorID != myID && isFriend(n.authorID) && !notifiedNearby.contains(n.id) {
            notifiedNearby.insert(n.id)
            let content = UNMutableNotificationContent()
            content.title = "\(n.authorName.split(separator: " ").first.map(String.init) ?? n.authorName) is nearby"
            content.body = n.isStatus ? "\(n.activity.line.capitalizedFirst) at \(n.place?.name ?? "a place near you")" : "At \(n.place?.name ?? "a place near you")"
            content.userInfo = ["nowID": n.id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "nearby.\(n.id)", content: content, trigger: nil))
        }
    }

    /// Venues near you, built from public Moments and NOW posts — most active first.
    func nearbyPlaces(latitude: Double, longitude: Double) -> [(place: SocialPlace, moments: Int, people: Int, live: Bool, km: Double)] {
        var byPlace: [String: (SocialPlace, [SocialMoment], Set<String>)] = [:]
        for m in nearbyMoments { if let p = m.place { var e = byPlace[p.id] ?? (p, [], []); e.1.append(m); e.2.formUnion(m.memberIDs); byPlace[p.id] = e } }
        for n in nearbyNow { if let p = n.place { var e = byPlace[p.id] ?? (p, [], []); e.2.insert(n.authorID); byPlace[p.id] = e } }
        return byPlace.values.map { (place: $0.0, moments: $0.1.count, people: $0.2.count, live: $0.1.contains(where: \.isLive), km: $0.0.distance(fromLatitude: latitude, longitude: longitude)) }
            .sorted { ($0.live ? 0 : 1, -$0.moments, $0.km) < ($1.live ? 0 : 1, -$1.moments, $1.km) }
    }

    func loadPlace(_ id: String) async {
        let ms = (try? await backend.moments(atPlace: id)) ?? []
        for m in ms { moments[m.id] = m }
        placeMoments[id] = ms.filter { !blocked.contains($0.creatorID) }
        claims[id] = try? await backend.claim(for: id)
    }

    /// Regulars: people who keep turning up here (2+ Moments at this venue). Computed, never inferred.
    func regulars(at placeID: String) -> [(id: String, name: String, visits: Int)] {
        var counts: [String: (String, Int)] = [:]
        for m in placeMoments[placeID] ?? [] {
            for (id, n) in zip(m.memberIDs, m.memberNames) { counts[id] = (n, (counts[id]?.1 ?? 0) + 1) }
        }
        return counts.filter { $0.value.1 >= 2 }.map { (id: $0.key, name: $0.value.0, visits: $0.value.1) }.sorted { $0.visits > $1.visits }
    }

    /// How many times I've been part of a Moment at this venue.
    func myVisits(at placeID: String) -> Int { moments.values.filter { $0.place?.id == placeID && $0.memberIDs.contains(myID) }.count }

    /// Your places: venues you've been to most, from your own Moments.
    var myPlaces: [(place: SocialPlace, visits: Int)] {
        var counts: [String: (SocialPlace, Int)] = [:]
        for m in momentsImIn { if let p = m.place { counts[p.id] = (p, (counts[p.id]?.1 ?? 0) + 1) } }
        return counts.values.map { (place: $0.0, visits: $0.1) }.sorted { $0.visits > $1.visits }
    }

    func refreshClaims() async { myClaims = (try? await backend.myClaims()) ?? []; for c in myClaims { claims[c.placeID] = c } }

    func claimPlace(_ place: SocialPlace, businessName: String, role: String, note: String) async -> Bool {
        guard subscriptions.canClaimPlace(existingClaims: myClaims.count) else {
            lastError = "The free plan includes one claimed place. MOMENT Pro lifts the limit."; return false
        }
        let c = PlaceClaim(id: place.id, placeID: place.id, ownerID: myID, ownerName: displayName, businessName: businessName.trimmed, role: role, note: note.trimmed, verified: false, createdAt: .now)
        do { let saved = try await backend.saveClaim(c); claims[place.id] = saved; if !myClaims.contains(where: { $0.id == saved.id }) { myClaims.append(saved) }; analytics.track(.placeClaimed); return true }
        catch { lastError = error.localizedDescription; return false }
    }

    // MARK: - Collections

    func refreshCollections() async { collections = (try? await backend.collections()) ?? [] }

    @discardableResult
    func createCollection(title: String, emoji: String, momentIDs: [String] = []) async -> MomentCollection? {
        let c = MomentCollection(id: "col_\(UUID().uuidString)", ownerID: myID, title: title.trimmed, emoji: emoji, momentIDs: momentIDs, createdAt: .now)
        do { let saved = try await backend.saveCollection(c); collections.append(saved); return saved } catch { lastError = error.localizedDescription; return nil }
    }

    func toggle(momentID: String, in collectionID: String) async {
        guard let i = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        var c = collections[i]
        if let j = c.momentIDs.firstIndex(of: momentID) { c.momentIDs.remove(at: j) } else { c.momentIDs.append(momentID) }
        collections[i] = c
        do { collections[i] = try await backend.saveCollection(c) } catch { lastError = error.localizedDescription }
    }

    func rename(collectionID: String, title: String, emoji: String) async {
        guard let i = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[i].title = title.trimmed; collections[i].emoji = emoji
        do { collections[i] = try await backend.saveCollection(collections[i]) } catch { lastError = error.localizedDescription }
    }

    func deleteCollection(_ id: String) async {
        collections.removeAll { $0.id == id }
        do { try await backend.deleteCollection(id: id) } catch { lastError = error.localizedDescription }
    }

    func moments(in c: MomentCollection) -> [SocialMoment] { c.momentIDs.compactMap { moments[$0] } }

    // MARK: - Derived: people & year

    /// People you were in Moments with but don't follow yet — the honest "suggested" list.
    var peopleSuggestions: [(id: String, name: String, shared: Int)] {
        var counts: [String: (String, Int)] = [:]
        for m in moments.values where m.memberIDs.contains(myID) {
            for (id, name) in zip(m.memberIDs, m.memberNames) where id != myID && !graph.following.contains(id) && !blocked.contains(id) {
                counts[id] = (name, (counts[id]?.1 ?? 0) + 1)
            }
        }
        return counts.map { (id: $0.key, name: $0.value.0, shared: $0.value.1) }.sorted { $0.shared > $1.shared }
    }

    struct YearSummary { var year: Int; var moments: Int; var people: Int; var places: Int; var photos: Int; var topPerson: String?; var topPlace: String?; var busiestMonth: String? }

    /// Real numbers from the Moments you were part of this year. Nothing invented.
    func yearSummary(_ year: Int = Calendar.current.component(.year, from: .now)) -> YearSummary? {
        let cal = Calendar.current
        let mine = moments.values.filter { $0.memberIDs.contains(myID) && cal.component(.year, from: $0.startAt ?? $0.createdAt) == year }
        guard !mine.isEmpty else { return nil }
        var people: [String: Int] = [:], places: [String: Int] = [:], months: [Int: Int] = [:]
        for m in mine {
            for (id, n) in zip(m.memberIDs, m.memberNames) where id != myID { people[n, default: 0] += 1 }
            if let p = m.coarsePlace, !p.isEmpty { places[p, default: 0] += 1 }
            months[cal.component(.month, from: m.startAt ?? m.createdAt), default: 0] += 1
        }
        let busiest = months.max { $0.value < $1.value }.map { cal.monthSymbols[$0.key - 1] }
        return YearSummary(year: year, moments: mine.count, people: people.count, places: places.count, photos: mine.reduce(0) { $0 + $1.mediaCount }, topPerson: people.max { $0.value < $1.value }?.key, topPlace: places.max { $0.value < $1.value }?.key, busiestMonth: busiest)
    }

    func updateProfile(displayName: String, handle: String, bio: String, avatar: Data?) async -> Bool {
        do {
            me = try await backend.updateProfile(displayName: displayName, handle: handle, bio: bio, avatar: avatar)
            settings.displayName = displayName
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    // MARK: - Feed

    func refreshFeed(notify: Bool = false) async {
        isLoadingFeed = true
        defer { isLoadingFeed = false }
        do {
            let page = try await backend.feed(cursor: nil)
            for m in page.items { moments[m.id] = m }
            await rebuildGraph(from: page.items)
            feed = FeedRanker.rank(page.items, me: myID, graph: graph, seen: seen)
            detectNewContributions(page.items, notify: notify)
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
        var isTeaser = false
        var initialMemberIDs: [String] = []
        var place: SocialPlace? = nil
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
        let locationName = input.locationName ?? input.place?.name
        let draft = MomentDraft(title: input.title.isBlank ? "Untitled Moment" : input.title.trimmed, description: input.description.trimmed, startAt: input.startAt ?? dates.first, endAt: input.endAt ?? (dates.count > 1 ? dates.last : nil), locationName: locationName, coarsePlace: input.place.map { Self.coarse($0.area.isEmpty ? $0.name : $0.area) } ?? input.locationName.map(Self.coarse), visibility: input.visibility, templateID: input.templateID, remixedFromID: input.remixedFromID, isLive: input.isLive, coverData: prepared.first.flatMap { MediaPipeline.thumbnail($0.data, side: 1080) }, isTeaser: input.isTeaser, initialMemberIDs: input.initialMemberIDs, place: input.place)
        do {
            var m = try await backend.createMoment(draft)
            // CloudKit adds people through the share; the in-memory backend already did it in create.
            if !input.initialMemberIDs.isEmpty, backend is CloudKitBackend { _ = try? await backend.share(momentID: m.id, with: input.initialMemberIDs); m = (try? await backend.moment(id: m.id)) ?? m }
            moments[m.id] = m
            if analytics.count(.momentCreated) == 0 { analytics.track(.firstMomentCreated) }
            analytics.track(.momentCreated, category: input.visibility.rawValue)
            await enqueue(prepared: prepared, videos: input.videoURLs, note: input.note, momentID: m.id, author: me)
            if input.remixedFromID != nil { analytics.track(.momentRemixed) }
            return m
        } catch { lastError = error.localizedDescription; return nil }
    }

    /// One tap: a live, open Moment for whatever is happening right now — the QR is the invite.
    func startActivity(title: String, kind: ActivityKind, place: String?, venue: SocialPlace? = nil, openToAnyone: Bool, isPublic: Bool = false) async -> SocialMoment? {
        var input = NewMomentInput(title: title.isBlank ? kind.defaultTitle : title.trimmed, visibility: isPublic ? .publicAll : openToAnyone ? .group : .friends, templateID: "activity.\(kind.rawValue)", isLive: true)
        input.locationName = place
        input.place = venue
        input.startAt = .now
        guard let m = await createMoment(input) else { return nil }
        // Make the link exist immediately so the QR is scannable the second the screen appears.
        _ = await shareLink(momentID: m.id)
        analytics.track(.activityStarted, category: kind.rawValue)
        return moments[m.id] ?? m
    }

    enum ActivityKind: String, CaseIterable, Sendable {
        case party, trip, dinner, wedding, concert, run, festival, game, meetup, other
        var emoji: String { switch self { case .party: "🎉"; case .trip: "✈️"; case .dinner: "🍽️"; case .wedding: "💍"; case .concert: "🎶"; case .run: "🏃"; case .festival: "🎪"; case .game: "🏟️"; case .meetup: "☕️"; case .other: "✨" } }
        var label: String { rawValue.capitalizedFirst }
        var defaultTitle: String {
            let day = Date.now.formatted(.dateTime.weekday(.wide))
            switch self {
            case .party: return "\(day) night"; case .trip: return "The trip"; case .dinner: return "Dinner"; case .wedding: return "The wedding"; case .concert: return "The show"
            case .run: return "\(day) run"; case .festival: return "The festival"; case .game: return "Match day"; case .meetup: return "\(day) meetup"; case .other: return "Right now"
            }
        }
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

    /// "I WAS THERE" on a Moment you can see but weren't invited to.
    func join(momentID: String) async -> Bool {
        if let m = moments[momentID], !subscriptions.canAdmit(attendees: m.memberIDs.count) {
            lastError = "This activity is full (\(SubscriptionService.freeEventAttendees) people). The host can lift the limit with MOMENT Pro."
            return false
        }
        do {
            let m = try await backend.join(momentID: momentID); moments[momentID] = m
            analytics.track(.momentJoined); Haptics.completed()
            await refreshFeed()
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    /// Two of your Moments that look like the same event: same day, overlapping people.
    func mergeCandidates(for momentID: String) -> [SocialMoment] {
        guard let m = moments[momentID], m.creatorID == myID else { return [] }
        let day = m.startAt ?? m.createdAt
        return moments.values.filter { o in
            o.id != m.id && o.creatorID == myID && Calendar.current.isDate(o.startAt ?? o.createdAt, inSameDayAs: day) && !Set(o.memberIDs).intersection(m.memberIDs).subtracting([myID]).isEmpty
        }
    }

    func merge(sourceID: String, into targetID: String) async -> Bool {
        do {
            let m = try await backend.merge(sourceID: sourceID, into: targetID)
            moments[sourceID] = nil; contributions[sourceID] = nil
            moments[targetID] = m
            await loadMoment(targetID); await refreshFeed()
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    // MARK: - Groups

    func refreshGroups() async { groups = (try? await backend.groups()) ?? [] }

    @discardableResult
    func createGroup(name: String, emoji: String, members: [SocialUser]) async -> SocialGroup? {
        guard let me else { return nil }
        let g = SocialGroup(id: "grp_\(UUID().uuidString)", ownerID: me.id, name: name.trimmed, emoji: emoji, memberIDs: [me.id] + members.map(\.id), memberNames: [me.displayName] + members.map(\.displayName), conversationID: nil, createdAt: .now)
        do { let saved = try await backend.saveGroup(g); groups.append(saved); await refreshInbox(); return saved } catch { lastError = error.localizedDescription; return nil }
    }

    func add(members: [SocialUser], to groupID: String) async {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        var g = groups[i]
        for u in members where !g.memberIDs.contains(u.id) { g.memberIDs.append(u.id); g.memberNames.append(u.displayName) }
        do { groups[i] = try await backend.saveGroup(g) } catch { lastError = error.localizedDescription }
    }

    func leaveGroup(_ id: String) async {
        groups.removeAll { $0.id == id }
        do { try await backend.leaveGroup(id: id) } catch { lastError = error.localizedDescription }
    }

    /// Moments where every member of the group was there (or the creator picked the group).
    func moments(for group: SocialGroup) -> [SocialMoment] {
        let members = Set(group.memberIDs)
        return moments.values.filter { Set($0.memberIDs).intersection(members).count >= min(members.count, 2) && $0.memberIDs.contains(myID) }.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Time Machine & highlights

    /// Moments from this day in previous years, grouped by how many years ago.
    var timeMachine: [(yearsAgo: Int, moments: [SocialMoment])] {
        let cal = Calendar.current
        let today = cal.dateComponents([.month, .day], from: .now)
        let thisYear = cal.component(.year, from: .now)
        var buckets: [Int: [SocialMoment]] = [:]
        for m in moments.values where m.memberIDs.contains(myID) {
            let d = m.startAt ?? m.createdAt
            let c = cal.dateComponents([.month, .day, .year], from: d)
            guard c.month == today.month, abs((c.day ?? 0) - (today.day ?? 0)) <= 1, let y = c.year, y < thisYear else { continue }
            buckets[thisYear - y, default: []].append(m)
        }
        return buckets.keys.sorted().map { (yearsAgo: $0, moments: buckets[$0]!.sorted { $0.createdAt > $1.createdAt }) }
    }

    struct Highlights { var mostReacted: Contribution?; var mostActiveHour: Date?; var mostActiveCount: Int; var addedMost: (name: String, count: Int)?; var firstAndLast: (Date, Date)? }

    /// "THE MOMENT" — computed from reactions and timestamps only. Nothing is guessed.
    func highlights(for momentID: String) -> Highlights? {
        let all = allContributions(momentID).filter { $0.uploadState == .uploaded }
        guard !all.isEmpty else { return nil }
        let mostReacted = all.filter { $0.reactionCounts.values.reduce(0, +) > 0 }.max { $0.reactionCounts.values.reduce(0, +) < $1.reactionCounts.values.reduce(0, +) }
        let times = all.map { $0.originalTimestamp ?? $0.createdAt }
        let cal = Calendar.current
        let byHour = Dictionary(grouping: times) { cal.dateInterval(of: .hour, for: $0)?.start ?? $0 }
        let busiest = byHour.max { $0.value.count < $1.value.count }
        let byAuthor = Dictionary(grouping: all, by: \.authorName).mapValues(\.count).max { $0.value < $1.value }
        return Highlights(mostReacted: mostReacted, mostActiveHour: byHour.count > 1 ? busiest?.key : nil, mostActiveCount: busiest?.value.count ?? 0, addedMost: byAuthor.map { (name: $0.key, count: $0.value) }, firstAndLast: times.count > 1 ? (times.min()!, times.max()!) : nil)
    }

    /// Passport: places, people, trips — the shape of a life in Moments.
    struct Passport { var places: [(name: String, count: Int)]; var people: Int; var trips: Int; var nights: Int; var events: Int; var years: [Int] }
    var passport: Passport {
        let mine = momentsImIn
        var places: [String: Int] = [:]
        for m in mine { if let p = m.coarsePlace, !p.isEmpty { places[p, default: 0] += 1 } }
        let people = Set(mine.flatMap(\.memberIDs)).subtracting([myID]).count
        let trips = mine.filter { if let s = $0.startAt, let e = $0.endAt { return !Calendar.current.isDate(s, inSameDayAs: e) }; return false }.count
        let nights = mine.filter { Calendar.current.component(.hour, from: $0.startAt ?? $0.createdAt) >= 19 }.count
        let events = mine.filter { $0.memberIDs.count >= 5 }.count
        let years = Array(Set(mine.map { Calendar.current.component(.year, from: $0.startAt ?? $0.createdAt) })).sorted(by: >)
        return Passport(places: places.map { (name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }, people: people, trips: trips, nights: nights, events: events, years: years)
    }

    func setCover(momentID: String, from contribution: Contribution) async {
        guard let img = await image(for: contribution.media), let data = MediaPipeline.thumbnail(img.jpegData(compressionQuality: 0.9) ?? Data(), side: 1080) else { return }
        do { moments[momentID] = try await backend.setCover(momentID: momentID, data: data); imageCache[momentID + "/cover"] = nil } catch { lastError = error.localizedDescription }
    }

    func isFeatured(_ id: String) -> Bool { settings.featuredMomentIDs.contains(id) }
    func toggleFeatured(_ id: String) {
        if let i = settings.featuredMomentIDs.firstIndex(of: id) { settings.featuredMomentIDs.remove(at: i) }
        else { settings.featuredMomentIDs = Array((settings.featuredMomentIDs + [id]).suffix(3)) }
    }
    var featured: [SocialMoment] { settings.featuredMomentIDs.compactMap { moments[$0] } }

    /// Title / place / people search over Moments you can see.
    func search(moments query: String) -> [SocialMoment] {
        let q = query.lowercased().trimmed
        guard !q.isEmpty else { return momentsImIn }
        return moments.values.filter { m in
            m.title.lowercased().contains(q) || (m.coarsePlace?.lowercased().contains(q) ?? false) || m.memberNames.contains { $0.lowercased().contains(q) } || m.description.lowercased().contains(q)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Cached dominant colour per cover, so pages and cards can take on the Moment's own tint.
    private var colorCache: [String: Color] = [:]
    func tint(for moment: SocialMoment) async -> Color {
        let key = moment.coverRef?.remoteID ?? moment.coverRef?.localRef ?? moment.id
        if let c = colorCache[key] { return c }
        guard let img = await image(for: moment.coverRef), let c = ImageColor.dominant(img) else { return MColor.accent }
        colorCache[key] = c
        return c
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
            // Free-tier attendee cap (the host's plan is enforced server-side once there is a server).
            if !subscriptions.canAdmit(attendees: m.memberIDs.count - 1) {
                try? await backend.leaveMoment(id: m.id)
                pendingInviteError = "This activity is full (\(SubscriptionService.freeEventAttendees) people)."
                return
            }
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

    func postNow(text: String, photo: Data?, place: String?, activity: NowPost.Activity = .none, hours: Double = 24, venue: SocialPlace? = nil) async -> Bool {
        guard let me else { return false }
        if case .blocked(let why) = ContentModeration.check(text) { lastError = why; return false }
        var ref: MediaRef? = nil
        if let photo, let p = MediaPipeline.preparePhoto(photo), let local = try? await media.store(p.data, extension: "jpg") { ref = MediaRef(kind: .photo, localRef: local, remoteID: nil, width: p.width, height: p.height) }
        let post = NowPost(id: UUID().uuidString, authorID: me.id, authorName: me.displayName, text: text.trimmed, media: ref, createdAt: .now, expiresAt: .now.addingTimeInterval(hours * 3600), coarsePlace: (place ?? venue?.area).map(Self.coarse), savedToMomentID: nil, activity: activity, place: venue)
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

    func joinNow(_ post: NowPost) async {
        do {
            let updated = try await backend.joinNow(id: post.id)
            if let i = nowPosts.firstIndex(where: { $0.id == post.id }) { nowPosts[i] = updated }
            Haptics.completed()
        } catch { lastError = error.localizedDescription }
    }

    /// "MAKE THIS A MOMENT": a spontaneous meetup becomes a shared Moment with everyone who joined.
    func makeMoment(from post: NowPost) async -> SocialMoment? {
        let title = post.activity != .none ? "\(post.activity.label) · \(post.createdAt.formatted(.dateTime.weekday(.wide)))" : (post.text.isBlank ? "Tonight" : String(post.text.prefix(40)))
        var input = NewMomentInput(title: title, visibility: .group, isLive: true)
        input.locationName = post.coarsePlace
        input.initialMemberIDs = ([post.authorID] + post.joinerIDs).filter { $0 != myID }
        guard let m = await createMoment(input) else { return nil }
        await saveNow(post, to: m.id)
        return m
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
        await refreshFeed(notify: true)
        await refreshInbox()
    }

    /// Only a remote change (silent push) may notify; foreground refreshes just update the baseline,
    /// so your own uploads never produce a "new additions" alert.
    private func detectNewContributions(_ items: [SocialMoment], notify: Bool) {
        for m in items where m.memberIDs.contains(myID) {
            if notify, settings.socialNotifications, let old = lastContributionCounts[m.id], m.contributionCount > old, m.memberIDs.count > 1 {
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
