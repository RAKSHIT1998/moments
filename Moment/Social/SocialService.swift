import Foundation
import SwiftUI
import UserNotifications
import StoreKit

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
    var identity: IdentityService?

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
    /// Everything public on the globe that the last camera position asked for (merged, de-duplicated).
    private(set) var exploreMoments: [String: SocialMoment] = [:]
    private(set) var exploreNow: [String: NowPost] = [:]
    private(set) var myClaims: [PlaceClaim] = []
    // Creator economy
    private(set) var creatorPlans: [String: CreatorPlan] = [:]
    private(set) var myPlan: CreatorPlan?
    private(set) var mySubscriptions: [CreatorSubscription] = []
    private(set) var subscribers: [CreatorSubscription] = []
    private(set) var tipsReceived: [CreatorTip] = []
    private(set) var creatorProducts: [String: Product] = [:]
    private(set) var purchasing = false
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
            if let mesh = backend as? DecentralizedBackend { await mesh.startObserving { [weak self] in Task { @MainActor in self?.scheduleMeshRefresh() } } }
            await startTypingObserver()
            if let identity, me?.publicKey != identity.publicKeyBase64 {
                try? await backend.publishIdentity(publicKey: identity.publicKeyBase64, momentID: identity.momentID)
                me = try? await backend.currentUser()
            }
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
        async let e: () = refreshCreator()
        _ = await (f, n, i, s, c, g, e)
        hasLoadedOnce = true
    }

    // MARK: - Creator economy

    func refreshCreator() async {
        myPlan = try? await backend.creatorPlan(for: myID)
        if let myPlan { creatorPlans[myID] = myPlan }
        mySubscriptions = (try? await backend.mySubscriptions()) ?? []
        subscribers = myPlan == nil ? [] : ((try? await backend.subscribers()) ?? [])
        tipsReceived = myPlan == nil ? [] : ((try? await backend.tips()) ?? [])
        if let mesh = backend as? DecentralizedBackend { await mesh.processGrants() }
        if creatorProducts.isEmpty, let products = try? await Product.products(for: CreatorPlan.Tier.allCases.map(\.productID) + CreatorTip.Amount.allCases.map(\.productID)) {
            creatorProducts = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        }
    }
    /// Creators we've already asked about, so feed cards don't re-query for people who sell nothing.
    private(set) var checkedPlans: Set<String> = []
    func loadCreatorPlan(_ userID: String) async {
        checkedPlans.insert(userID)
        if let p = try? await backend.creatorPlan(for: userID) { creatorPlans[userID] = p } else { creatorPlans[userID] = nil }
    }
    func plan(for userID: String) -> CreatorPlan? { creatorPlans[userID] }
    func isSubscribed(to userID: String) -> Bool { mySubscriptions.contains { $0.creatorID == userID && $0.isActive } }
    func subscription(to userID: String) -> CreatorSubscription? { mySubscriptions.first { $0.creatorID == userID && $0.isActive } }
    /// Localized price from the App Store, else the reference amount.
    func price(for tier: CreatorPlan.Tier) -> String { creatorProducts[tier.productID]?.displayPrice ?? tier.fallbackPrice }
    var earningsEstimate: Double { CreatorEconomics.creatorEstimate(subscribers, tips: tipsReceived) }
    func price(for amount: CreatorTip.Amount) -> String { creatorProducts[amount.productID]?.displayPrice ?? amount.fallbackPrice }

    /// A one-off thank-you: consumable App Store purchase, then a signed record for the creator. Returns true when sent.
    func tip(creatorID: String, momentID: String?, amount: CreatorTip.Amount, note: String) async -> Bool {
        purchasing = true; defer { purchasing = false }
        var transactionID: String? = nil
        if !isTestHost, let product = creatorProducts[amount.productID] {
            do {
                switch try await product.purchase() {
                case .success(let verification):
                    guard case .verified(let t) = verification else { lastError = "Purchase couldn't be verified."; return false }
                    await t.finish(); transactionID = String(t.id)
                case .userCancelled, .pending: return false
                @unknown default: return false
                }
            } catch { lastError = error.localizedDescription; return false }
        } else if !isTestHost { lastError = "Prices aren't available right now. Try again in a moment."; return false }
        do { _ = try await backend.tip(creatorID: creatorID, momentID: momentID, amount: amount, note: note.trimmed, transactionID: transactionID); analytics.track(.creatorTipped, category: amount.rawValue); return true }
        catch { lastError = error.localizedDescription; return false }
    }
    var activeSubscriberCount: Int { subscribers.filter(\.isActive).count }

    @discardableResult
    func savePlan(title: String, pitch: String, tier: CreatorPlan.Tier, perks: [String], payoutHint: String) async -> Bool {
        let p = CreatorPlan(creatorID: myID, creatorName: displayName, title: title.trimmed, pitch: pitch.trimmed, tier: tier, perks: perks.map(\.trimmed).filter { !$0.isEmpty }, payoutHint: payoutHint.trimmed, createdAt: myPlan?.createdAt ?? .now)
        do {
            let saved = try await backend.saveCreatorPlan(p)
            if myPlan == nil { analytics.track(.creatorPlanCreated) }
            myPlan = saved; creatorPlans[myID] = saved
            return true
        } catch { lastError = error.localizedDescription; return false }
    }
    func removePlan() async { try? await backend.removeCreatorPlan(); myPlan = nil; creatorPlans[myID] = nil; subscribers = [] }

    /// Pays through the App Store (non-renewing 30-day product for the creator's tier), then records the subscription.
    /// Returns true when the person is now subscribed.
    func subscribe(to creatorID: String) async -> Bool {
        var cached = creatorPlans[creatorID]
        if cached == nil { cached = try? await backend.creatorPlan(for: creatorID) }
        guard let plan = cached else { lastError = "This person isn't selling anything yet."; return false }
        purchasing = true; defer { purchasing = false }
        var transactionID: String? = nil
        if !isTestHost, let product = creatorProducts[plan.tier.productID] {
            do {
                switch try await product.purchase() {
                case .success(let verification):
                    guard case .verified(let t) = verification else { lastError = "Purchase couldn't be verified."; return false }
                    await t.finish(); transactionID = String(t.id)
                case .userCancelled, .pending: return false
                @unknown default: return false
                }
            } catch { lastError = error.localizedDescription; return false }
        } else if !isTestHost {
            lastError = "Prices aren't available right now. Try again in a moment."; return false
        }
        do {
            let s = try await backend.subscribe(to: creatorID, tier: plan.tier, transactionID: transactionID, days: 30)
            mySubscriptions.removeAll { $0.creatorID == creatorID }; mySubscriptions.append(s)
            analytics.track(.creatorSubscribed, category: plan.tier.rawValue)
            await refreshFeed()
            return true
        } catch { lastError = error.localizedDescription; return false }
    }
    /// Unit tests and the in-process demo have no App Store; a subscription there is recorded without a transaction.
    private var isTestHost: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.arguments.contains("-uitest") || ProcessInfo.processInfo.arguments.contains("-demo") || settings.demoMode }

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

    /// The globe: public Moments within the visible region. Same radius query as Nearby, so the
    /// camera is the only "location" involved — never the device's own fix unless the user asked.
    func refreshExplore(latitude: Double, longitude: Double, radiusKm: Double) async {
        let r = max(1, min(radiusKm, 20_000))
        async let m = backend.nearby(latitude: latitude, longitude: longitude, radiusKm: r)
        async let n = backend.nowNearby(latitude: latitude, longitude: longitude, radiusKm: r)
        for x in (try? await m) ?? [] where !blocked.contains(x.creatorID) && !muted.contains(x.creatorID) { exploreMoments[x.id] = x; moments[x.id] = x }
        for x in (try? await n) ?? [] where !blocked.contains(x.authorID) && !muted.contains(x.authorID) && !x.isExpired { exploreNow[x.id] = x }
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
        // Ties resolve by name so the summary is stable between launches.
        func top(_ d: [String: Int]) -> String? { d.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key }
        let busiest = months.max { ($0.value, $1.key) < ($1.value, $0.key) }.map { cal.monthSymbols[$0.key - 1] }
        return YearSummary(year: year, moments: mine.count, people: people.count, places: places.count, photos: mine.reduce(0) { $0 + $1.mediaCount }, topPerson: top(people), topPlace: top(places), busiestMonth: busiest)
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
        var draft = MomentDraft(title: input.title.isBlank ? "Untitled Moment" : input.title.trimmed, description: input.description.trimmed, startAt: input.startAt ?? dates.first, endAt: input.endAt ?? (dates.count > 1 ? dates.last : nil), locationName: locationName, coarsePlace: input.place.map { Self.coarse($0.area.isEmpty ? $0.name : $0.area) } ?? input.locationName.map(Self.coarse), visibility: input.visibility, templateID: input.templateID, remixedFromID: input.remixedFromID, isLive: input.isLive, coverData: prepared.first.flatMap { MediaPipeline.thumbnail($0.data, side: 1080) }, isTeaser: input.isTeaser, initialMemberIDs: input.initialMemberIDs, place: input.place)
        if let identity {
            // Capture the key value now: the closure runs inside the backend, off the main actor.
            let key = identity.privateKey, pk = identity.publicKeyBase64, creator = me.id, title = draft.title
            draft.signer = { id, at in
                let sig = (try? key.signature(for: Data(IdentityService.momentMessage(id: id, creatorID: creator, title: title, createdAt: at).utf8)))?.base64EncodedString() ?? ""
                return (signature: sig, publicKey: pk)
            }
        }
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

    /// Signature check for a Moment: true only if the creator's published key verifies it.
    func isVerified(_ m: SocialMoment) -> Bool {
        guard let sig = m.signature, let pk = m.creatorPublicKey else { return false }
        return IdentityService.verify(sig, message: IdentityService.momentMessage(id: m.id, creatorID: m.creatorID, title: m.title, createdAt: m.signedAt ?? m.createdAt), publicKeyBase64: pk)
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

    /// iCloud share links, or decentralised invites: `moment://join/<eventID>#<momentKey>` — the key in the
    /// fragment is what makes a private Moment readable, and it never touches a server.
    static func isInviteURL(_ url: URL) -> Bool {
        if url.scheme == "moment", url.host() == "join", !url.lastPathComponent.isEmpty { return true }
        return (url.host()?.hasSuffix("icloud.com") ?? false) && url.path().contains("/share/")
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
        applySavedNow()
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
        // "I kept this one" is this phone's own record — the NOW itself is unchanged for everyone else,
        // so it has to survive the next refresh rather than living only in the array.
        var saved = savedNowIDs; saved[post.id] = momentID; savedNowIDs = saved
        if let i = nowPosts.firstIndex(where: { $0.id == post.id }) { nowPosts[i].savedToMomentID = momentID }
        analytics.track(.nowSaved)
    }

    private var savedNowIDs: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "now.savedTo") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "now.savedTo") }
    }
    /// Re-applies what this phone kept, after any refresh replaces the posts.
    private func applySavedNow() {
        let saved = savedNowIDs
        guard !saved.isEmpty else { return }
        for i in nowPosts.indices { if let m = saved[nowPosts[i].id] { nowPosts[i].savedToMomentID = m } }
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

    func loadMessages(_ conversationID: String) async { messages[conversationID] = (try? await backend.messages(conversationID: conversationID)) ?? []; await refreshSeen(conversationID) }

    func conversation(with userID: String) async -> Conversation? {
        do { let c = try await backend.conversation(with: userID); if !conversations.contains(where: { $0.id == c.id }) { conversations.insert(c, at: 0) }; return c } catch { lastError = error.localizedDescription; return nil }
    }

    func send(conversationID: String, text: String, momentID: String? = nil, photo: Data? = nil, voice: Data? = nil, replyTo: String? = nil) async -> Bool {
        guard let me else { return false }
        if case .blocked(let why) = ContentModeration.check(text) { lastError = why; return false }
        var ref: MediaRef? = nil
        var data: Data? = nil
        if let photo, let p = MediaPipeline.preparePhoto(photo), let local = try? await media.store(p.data, extension: "jpg") { ref = MediaRef(kind: .photo, localRef: local, remoteID: nil); data = p.data }
        if let voice, let local = try? await media.store(voice, extension: "m4a") { ref = MediaRef(kind: .voice, localRef: local, remoteID: nil, durationSeconds: VoiceNotePlayer.duration(of: voice)); data = voice }
        let m = DirectMessage(id: UUID().uuidString, conversationID: conversationID, authorID: me.id, authorName: me.displayName, text: text.trimmed, media: ref, momentID: momentID, createdAt: .now, replyToID: replyTo)
        do {
            let saved = try await backend.send(m, mediaData: data)
            messages[conversationID, default: []].append(saved)
            if !saved.isReaction, let i = conversations.firstIndex(where: { $0.id == conversationID }) {
                var c = conversations.remove(at: i)
                c.lastMessage = saved.text.isEmpty ? (momentID != nil ? "Shared a Moment" : (saved.media?.kind == .voice ? "Voice note" : "Photo")) : saved.text; c.updatedAt = .now
                conversations.insert(c, at: 0)
            }
            markRead(conversationID)
            analytics.track(.messageSent, category: saved.isReaction ? "reaction" : (momentID == nil ? "text" : "moment"))
            return true
        } catch { lastError = error.localizedDescription; return false }
    }
    /// One emoji, attached to a message. Sending the same one again removes nothing (it's a log); the UI shows the latest per person.
    func react(conversationID: String, messageID: String, emoji: String) async { _ = await send(conversationID: conversationID, text: emoji, replyTo: messageID) }
    func reactions(on message: DirectMessage) -> [DirectMessage] { (messages[message.conversationID] ?? []).filter { $0.isReaction && $0.replyToID == message.id } }
    func message(_ id: String, in conversationID: String) -> DirectMessage? { messages[conversationID]?.first { $0.id == id } }

    func groupConversation(_ group: SocialGroup) async -> Conversation? {
        do { let c = try await backend.conversation(forGroup: group); if !conversations.contains(where: { $0.id == c.id }) { conversations.insert(c, at: 0) }; return c } catch { lastError = error.localizedDescription; return nil }
    }

    // Read state lives on the phone: nobody else needs to know when you opened a chat.
    private var readAt: [String: Date] {
        get { (UserDefaults.standard.dictionary(forKey: "chat.readAt") as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) } }
        set { UserDefaults.standard.set(newValue.mapValues { $0.timeIntervalSince1970 }, forKey: "chat.readAt") }
    }
    func markRead(_ conversationID: String) {
        var r = readAt; r[conversationID] = .now; readAt = r; readTick += 1
        if let last = messages[conversationID]?.last(where: { !$0.isReaction }) { Task { try? await backend.markSeen(conversationID: conversationID, lastMessageID: last.id); await refreshSeen(conversationID) } }
    }
    // Read receipts and typing, per conversation.
    private(set) var seenBy: [String: [String: String]] = [:]
    private(set) var typingIn: [String: [String: Date]] = [:]
    func refreshSeen(_ conversationID: String) async { seenBy[conversationID] = (try? await backend.seen(conversationID: conversationID)) ?? [:] }
    /// Others who have seen my latest message in this conversation (names).
    func seenNames(for conversationID: String) -> [String] {
        guard let c = conversations.first(where: { $0.id == conversationID }), let mine = messages[conversationID]?.last(where: { $0.authorID == myID && !$0.isReaction }),
              let idx = messages[conversationID]?.firstIndex(where: { $0.id == mine.id }) else { return [] }
        let ids = messages[conversationID]?.prefix(through: idx).map(\.id) ?? []
        return zip(c.participantIDs, c.participantNames).filter { $0.0 != myID && (seenBy[conversationID]?[$0.0]).map { ids.contains($0) } == true }.map { $0.1 }
    }
    func typingNames(for conversationID: String) -> [String] {
        guard let c = conversations.first(where: { $0.id == conversationID }) else { return [] }
        let live = (typingIn[conversationID] ?? [:]).filter { $0.value.timeIntervalSinceNow > -6 }
        return zip(c.participantIDs, c.participantNames).filter { live[$0.0] != nil }.map { $0.1 }
    }
    private var lastTypingSent: [String: Date] = [:]
    func noteTyping(_ conversationID: String) {
        guard (lastTypingSent[conversationID]?.timeIntervalSinceNow ?? -10) < -3 else { return }
        lastTypingSent[conversationID] = .now
        Task { await backend.setTyping(conversationID: conversationID, typing: true) }
    }
    private(set) var typingTick = 0
    func startTypingObserver() async {
        await backend.onTyping { [weak self] conv, user in Task { @MainActor in self?.typingIn[conv, default: [:]][user] = .now; self?.typingTick += 1
            try? await Task.sleep(for: .seconds(6.5)); self?.typingTick += 1 } }
    }
    private(set) var readTick = 0
    func isUnread(_ c: Conversation) -> Bool { _ = readTick; return c.updatedAt > (readAt[c.id] ?? .distantPast) && !c.lastMessage.isEmpty }
    var unreadChats: Int { conversations.filter { isUnread($0) }.count }

    // MARK: - Meet

    private(set) var myDating: DatingProfile?
    var pendingConversationID: String?
    private(set) var meetCandidates: [MeetRanker.Candidate] = []
    private(set) var likesReceived: [DatingLike] = []
    private(set) var likesSent: [DatingLike] = []
    private(set) var meetMatches: [MeetMatch] = []
    private(set) var meetLoaded = false

    /// People I follow or who follow me — used for "hide from people I know".
    private var knownIDs: Set<String> { graph.following.union(graph.followers) }

    func refreshMeet() async {
        myDating = try? await backend.datingProfile(for: myID)
        likesReceived = (try? await backend.likesReceived()) ?? []
        likesSent = (try? await backend.likesSent()) ?? []
        if let me = myDating {
            let all = (try? await backend.datingCandidates()) ?? []
            let passed = Set((try? await backend.passedUserIDs()) ?? [])
            let liveNow = nowPosts + nearbyNow.filter { n in !nowPosts.contains { $0.id == n.id } }
            meetCandidates = MeetRanker.rank(me: me, candidates: all, moments: Array(moments.values), nows: liveNow, known: knownIDs, passed: passed, liked: Set(likesSent.map(\.toID)), blocked: blocked)
            var names = Dictionary(uniqueKeysWithValues: all.map { ($0.userID, $0.displayName) }); names[myID] = displayName
            meetMatches = MeetRanker.matches(me: myID, sent: likesSent, received: likesReceived, names: names) { other in MeetRanker.overlaps(me: self.myID, other: other, moments: Array(self.moments.values), nows: liveNow) }
        } else { meetCandidates = []; meetMatches = [] }
        meetLoaded = true
    }
    func saveDating(_ p: DatingProfile) async -> Bool {
        do { myDating = try await backend.saveDatingProfile(p); analytics.track(.meetOptedIn); await refreshMeet(); return true } catch { lastError = error.localizedDescription; return false }
    }
    func leaveMeet() async { try? await backend.removeDatingProfile(); myDating = nil; meetCandidates = []; meetMatches = [] }
    /// Like → maybe match → the chat opens with the overlap as its first line.
    @discardableResult
    func like(_ c: MeetRanker.Candidate, note: String, prompt: String?) async -> MeetMatch? {
        do {
            let l = try await backend.like(userID: c.profile.userID, note: note, promptQuestion: prompt)
            UserDefaults.standard.set(note, forKey: "meet.note.\(l.id)")
            likesSent.append(l); meetCandidates.removeAll { $0.id == c.id }
            analytics.track(.meetLiked)
            let before = Set(meetMatches.map(\.id))
            await refreshMeet()
            if let m = meetMatches.first(where: { !before.contains($0.id) }) { analytics.track(.meetMatched); await openMatchChat(m); return meetMatches.first { $0.id == m.id } ?? m }
            return nil
        } catch { lastError = error.localizedDescription; return nil }
    }
    func pass(_ c: MeetRanker.Candidate) async { try? await backend.pass(userID: c.profile.userID); meetCandidates.removeAll { $0.id == c.id } }
    /// The match's chat starts with the reason you're talking, sent by whoever opens it first.
    func openMatchChat(_ m: MeetMatch) async {
        guard let other = m.other(than: myID), let c = await conversation(with: other.id) else { return }
        await loadMessages(c.id)
        if (messages[c.id] ?? []).isEmpty, let o = m.overlaps.first {
            _ = await send(conversationID: c.id, text: "It's a match. \(o.label).", momentID: o.momentID)
        }
        if let i = meetMatches.firstIndex(where: { $0.id == m.id }) { meetMatches[i].conversationID = c.id }
    }
    /// My own photos from my Moments — the only pool a Meet profile can draw from.
    var myPhotosForMeet: [MediaRef] {
        var sides: [Contribution] = []
        for m in moments.values { sides.append(contentsOf: allContributions(m.id)) }
        let mine = sides.filter { $0.authorID == myID && $0.kind == .photo && $0.media != nil }
        let sorted = mine.sorted { $0.createdAt > $1.createdAt }
        return sorted.compactMap { $0.media }
    }

    // MARK: - Storefront

    private(set) var mySets: [VaultSet] = []
    private(set) var setsByCreator: [String: [VaultSet]] = [:]
    private(set) var itemsBySet: [String: [VaultItem]] = [:]
    private(set) var myPurchases: [VaultPurchase] = []
    private(set) var mySales: [VaultPurchase] = []
    private(set) var offersByCreator: [String: [BookingOffer]] = [:]
    private(set) var myBookings: [Booking] = []
    private(set) var linksByCreator: [String: CreatorLinks] = [:]
    private(set) var busy = false

    /// Where the money goes through. Web (card) keeps the platform fee at 10%; Apple's rail can't.
    var rail: PaymentRail { settings.webCheckoutEnabled ? .web : .appStore }

    func refreshStorefront() async {
        mySets = (try? await backend.vaultSets(creatorID: myID)) ?? []
        setsByCreator[myID] = mySets
        myPurchases = (try? await backend.myPurchases()) ?? []
        mySales = (try? await backend.vaultSales()) ?? []
        myBookings = (try? await backend.myBookings()) ?? []
        offersByCreator[myID] = (try? await backend.bookingOffers(creatorID: myID)) ?? []
        linksByCreator[myID] = (try? await backend.creatorLinks(for: myID)) ?? CreatorLinks()
        if let mesh = backend as? DecentralizedBackend { await mesh.processGrants() }
    }
    func loadStorefront(_ creatorID: String) async {
        setsByCreator[creatorID] = (try? await backend.vaultSets(creatorID: creatorID)) ?? []
        offersByCreator[creatorID] = (try? await backend.bookingOffers(creatorID: creatorID)) ?? []
        linksByCreator[creatorID] = (try? await backend.creatorLinks(for: creatorID)) ?? CreatorLinks()
    }
    func sets(of creatorID: String) -> [VaultSet] { setsByCreator[creatorID] ?? [] }
    func offers(of creatorID: String) -> [BookingOffer] { offersByCreator[creatorID] ?? [] }
    func links(of creatorID: String) -> CreatorLinks { linksByCreator[creatorID] ?? CreatorLinks() }
    func hasBought(_ setID: String) -> Bool { myPurchases.contains { $0.setID == setID } }
    func isUnlocked(_ set: VaultSet) -> Bool { set.isFree || set.creatorID == myID || hasBought(set.id) }
    func loadItems(_ setID: String) async { itemsBySet[setID] = (try? await backend.vaultItems(setID: setID)) ?? [] }
    func items(_ setID: String) -> [VaultItem] { itemsBySet[setID] ?? [] }

    @discardableResult
    func saveSet(_ set: VaultSet, items: [VaultItem]) async -> VaultSet? {
        busy = true; defer { busy = false }
        do { let saved = try await backend.saveVaultSet(set, items: items, media: [:]); await refreshStorefront(); analytics.track(.setPublished); return saved }
        catch { lastError = error.localizedDescription; return nil }
    }
    func deleteSet(_ id: String) async { try? await backend.deleteVaultSet(id: id); await refreshStorefront() }

    /// Buys a set. Free sets need no payment; paid ones go through the rail the creator's platform uses.
    /// On the web rail the app hands off to the creator's checkout and records the reference it returns.
    func buySet(_ set: VaultSet, reference: String? = nil) async -> Bool {
        busy = true; defer { busy = false }
        do {
            _ = try await backend.buyVaultSet(id: set.id, rail: set.isFree ? .none : rail, reference: reference)
            myPurchases = (try? await backend.myPurchases()) ?? []
            await loadItems(set.id)
            if !set.isFree { analytics.track(.setPurchased, category: set.currency) }
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    @discardableResult
    func saveOffer(_ offer: BookingOffer) async -> BookingOffer? {
        do { let o = try await backend.saveBookingOffer(offer); await refreshStorefront(); return o } catch { lastError = error.localizedDescription; return nil }
    }
    func deleteOffer(_ id: String) async { try? await backend.deleteBookingOffer(id: id); await refreshStorefront() }
    func requestBooking(_ offer: BookingOffer, startsAt: Date, note: String, reference: String? = nil) async -> Booking? {
        busy = true; defer { busy = false }
        do {
            let b = try await backend.requestBooking(offerID: offer.id, creatorID: offer.creatorID, startsAt: startsAt, note: note, rail: rail, reference: reference)
            myBookings = (try? await backend.myBookings()) ?? []
            analytics.track(.bookingRequested, category: offer.kind.rawValue)
            // The request lands in the creator's chat so nothing depends on them opening a dashboard.
            if let c = await conversation(with: offer.creatorID) {
                _ = await send(conversationID: c.id, text: "Booked: \(offer.kind.label), \(offer.minutes > 0 ? "\(offer.minutes) min, " : "")\(offer.priceLabel()) — \(startsAt.formatted(date: .abbreviated, time: .shortened))." + (note.isBlank ? "" : " “\(note.trimmed)”"))
            }
            return b
        } catch { lastError = error.localizedDescription; return nil }
    }
    @discardableResult
    func setBooking(_ id: String, _ status: Booking.Status) async -> Booking? {
        do { let b = try await backend.setBookingStatus(id: id, status: status); myBookings = (try? await backend.myBookings()) ?? []; return b } catch { lastError = error.localizedDescription; return nil }
    }
    func saveLinks(_ l: CreatorLinks) async { try? await backend.saveCreatorLinks(l); linksByCreator[myID] = l }

    /// This month, after the platform fee on each rail. Sales and bookings included.
    var storefrontEarnings: Double { CreatorEconomics.creatorEstimate(subscribers, tips: tipsReceived, sales: mySales, bookings: myBookings.filter { $0.creatorID == myID }) }
    var isCreator: Bool { myPlan != nil || !mySets.isEmpty || !(offersByCreator[myID] ?? []).isEmpty }

    /// The creator feed: every set and subscribers-only Moment from people I follow or pay, newest first.
    private(set) var creatorFeed: [CreatorPost] = []
    func refreshCreatorFeed() async {
        // Whose shop to show: people I follow or pay, and anyone whose Moments already reach me.
        var ids = Set(graph.following)
        ids.formUnion(mySubscriptions.filter(\.isActive).map(\.creatorID))
        ids.formUnion(setsByCreator.keys)
        ids.formUnion(moments.values.map(\.creatorID))
        ids.insert(myID)
        for id in ids where setsByCreator[id] == nil { await loadStorefront(id) }
        for id in ids where creatorPlans[id] == nil && !checkedPlans.contains(id) { await loadCreatorPlan(id) }
        if myPurchases.isEmpty { myPurchases = (try? await backend.myPurchases()) ?? [] }
        let sets = ids.flatMap { setsByCreator[$0] ?? [] }
        var plans: [String: CreatorPlan] = [:]
        for id in ids { if let p = creatorPlans[id] { plans[id] = p } }
        creatorFeed = CreatorFeedBuilder.build(sets: sets, moments: Array(moments.values), plans: plans, purchases: Set(myPurchases.map(\.setID)), subscribedTo: Set(mySubscriptions.filter(\.isActive).map(\.creatorID)), me: myID, blocked: blocked)
    }

    // MARK: - Reels

    private(set) var reels: [Reel] = []
    private var seenReels: Set<String> = []
    /// Builds reels from what we already have, loading sides for the Moments that could carry one.
    func refreshReels() async {
        let candidates = moments.values.filter { !$0.isLocked && ($0.mediaCount >= 3 || $0.memberIDs.contains(myID) || $0.isLive) }.sorted { $0.createdAt > $1.createdAt }.prefix(18)
        for m in candidates where allContributions(m.id).isEmpty { _ = await loadMoment(m.id) }
        reels = ReelBuilder.build(moments: Array(moments.values), sides: { [weak self] id in self?.allContributions(id) ?? [] }, me: myID, seen: seenReels)
    }
    func markReelSeen(_ id: String) { seenReels.insert(id) }

    // MARK: - Replay video

    private(set) var exportingReplay = false
    /// Renders the Moment as a vertical video ready for the share sheet. Everything in it is real: the sides in
    /// order, who added them, when. The end card carries the invite link so whoever sees it can join.
    func exportReplay(momentID: String) async -> URL? {
        guard let m = moments[momentID] else { return nil }
        exportingReplay = true; defer { exportingReplay = false }
        let all = allContributions(momentID).filter { $0.uploadState == .uploaded }.sorted { ($0.originalTimestamp ?? $0.createdAt) < ($1.originalTimestamp ?? $1.createdAt) }
        var beats: [ReplayExporter.Beat] = []
        for c in all {
            if c.kind == .text { beats.append(.init(image: nil, note: c.caption, author: c.authorName, time: c.originalTimestamp ?? c.createdAt)) }
            else if c.kind == .photo, let img = await image(for: c.media) { beats.append(.init(image: img, note: nil, author: c.authorName, time: c.originalTimestamp ?? c.createdAt)) }
        }
        let link = (await shareLink(momentID: momentID))?.absoluteString ?? "moment://moment/\(momentID)"
        let subtitle = "\(m.memberIDs.count) \(m.memberIDs.count == 1 ? "person" : "people") · \(m.dateLabel)" + (m.coarsePlace.map { " · \($0)" } ?? "")
        do { let url = try await ReplayExporter.export(title: m.title, subtitle: subtitle, beats: beats, inviteLine: link); analytics.track(.replayExported); return url }
        catch { lastError = error.localizedDescription; return nil }
    }

    // MARK: - Media

    /// Stores a picked photo/clip in the local media store and returns a ref the storefront can carry.
    func storeLocalMedia(_ data: Data, kind: MediaRef.Kind) async -> MediaRef? {
        let prepared = kind == .photo ? (MediaPipeline.preparePhoto(data)?.data ?? data) : data
        guard let local = try? await media.store(prepared, extension: kind == .video ? "mp4" : "jpg") else { return nil }
        return MediaRef(kind: kind, localRef: local, remoteID: nil)
    }

    /// Raw bytes for non-image media (voice notes).
    func data(for ref: MediaRef) async -> Data? {
        if let local = ref.localRef, let d = try? await media.load(local) { return d }
        return try? await backend.download(ref)
    }

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

    /// Events arrive one at a time over mesh/relays; coalesce them into one refresh.
    private var meshRefreshTask: Task<Void, Never>?
    private func scheduleMeshRefresh() {
        meshRefreshTask?.cancel()
        meshRefreshTask = Task { try? await Task.sleep(for: .milliseconds(600)); guard !Task.isCancelled else { return }; await handleRemoteChange() }
    }

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
