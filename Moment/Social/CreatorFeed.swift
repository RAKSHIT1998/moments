import Foundation

/// The creator feed: one card per thing a creator published — a set of photos, or a subscribers-only
/// Moment. Locked cards say exactly what opens them and at what price. Nothing is hidden to tease;
/// the price is always on the lock.
struct CreatorPost: Identifiable, Sendable, Equatable {
    enum Source: Sendable, Equatable { case set(VaultSet) }
    /// What the viewer has to do to see it.
    enum Gate: Sendable, Equatable {
        case open                       // free, or already theirs
        case buy(priceMinor: Int, currency: String)
        case subscribe(tier: CreatorPlan.Tier, title: String)
    }
    var id: String
    var creatorID: String
    var creatorName: String
    var title: String
    var blurb: String
    var cover: MediaRef?
    var itemCount: Int
    var isVideo: Bool
    var createdAt: Date
    var gate: Gate
    var source: Source
    var isLocked: Bool { gate != .open }
    var setID: String? { if case .set(let s) = source { return s.id }; return nil }
    /// Kept so a tip can name what it's for; posts are sets now, so there is no Moment behind them.
    var momentID: String? { nil }
    func priceLabel(_ locale: Locale = .current) -> String? {
        switch gate {
        case .open: return nil
        case .buy(let minor, let currency): return (Double(minor) / 100).formatted(.currency(code: currency).locale(locale).precision(.fractionLength(0)))
        case .subscribe: return nil
        }
    }
}

enum CreatorFeedBuilder {
    /// Every post the viewer can see or buy from creators they know, newest first. What they've paid for
    /// shows open, so the feed is also their library.
    static func build(sets: [VaultSet], plans: [String: CreatorPlan], purchases: Set<String>, subscribedTo: Set<String>, me: String, blocked: Set<String> = []) -> [CreatorPost] {
        var out: [CreatorPost] = []
        for s in sets where s.visible && !blocked.contains(s.creatorID) {
            let mine = s.creatorID == me
            let gate: CreatorPost.Gate
            if mine || s.isFree || purchases.contains(s.id) { gate = .open }
            else if s.subscribersOnly {
                if subscribedTo.contains(s.creatorID) { gate = .open }
                else if let plan = plans[s.creatorID] { gate = .subscribe(tier: plan.tier, title: plan.title) }
                else { continue }   // a lock we can't explain isn't shown at all
            }
            else { gate = .buy(priceMinor: s.priceMinor, currency: s.currency) }
            out.append(CreatorPost(id: "s_" + s.id, creatorID: s.creatorID, creatorName: s.creatorName, title: s.title, blurb: s.blurb, cover: s.cover, itemCount: s.itemCount, isVideo: s.isVideo, createdAt: s.createdAt, gate: gate, source: .set(s)))
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }
}

/// What the viewer's own history says about a creator, and what they've already looked at. All of it
/// is computed on the phone from things that actually happened — follows, purchases, subscriptions,
/// opens. Nothing here is inferred from behaviour the app doesn't record, and nothing leaves the device.
struct FeedContext: Sendable {
    var me: String = ""
    var following: Set<String> = []
    var subscribedTo: Set<String> = []
    /// Creators this viewer has ever paid for a set from — the strongest signal there is, because
    /// money is the only engagement this product cares about.
    var boughtFrom: Set<String> = []
    /// Post ids already opened. A post isn't hidden once seen, only pushed down.
    var seen: Set<String> = []
    /// Set ids the viewer bought one at a time. These are their library — worth keeping reachable,
    /// but not news. Deliberately *not* the same as everything from a creator they subscribe to:
    /// subscription posts are what the subscription was for, and demoting them would defeat it.
    var purchasedSets: Set<String> = []
    /// Creators whose free work the viewer has opened but never paid for. Used to stop cold asks
    /// from crowding out the free posts that actually convert.
    var openedFreeFrom: Set<String> = []
}

/// Ordering the creator feed.
///
/// The product question this answers is narrow: **of the posts a viewer could pay for right now,
/// which should they see first?** So the weights follow money and consent, not time-on-app —
/// there is no watch-time signal here, no infinite-scroll objective, and nothing that rewards a
/// creator for posting more often than they have things to say.
///
/// Three rules it keeps, in order:
/// 1. **A creator you already pay for comes first.** You bought the relationship; the feed honours it.
/// 2. **A stranger's free post beats a stranger's locked post.** Free work is how someone is found;
///    a cold ask from a creator you've never opened is the weakest thing in the feed, not the strongest.
/// 3. **No creator takes two slots in a row** while anyone else has something unseen. Prolific
///    posting shouldn't bury everyone else.
enum CreatorFeedRanker {
    /// Tuned so the ordering is explainable rather than magic: each term says what it's worth.
    struct Weights: Sendable {
        /// Value of a post at age zero, falling to zero over `freshDays`.
        var freshness = 2.0
        var freshDays = 5.0
        /// You pay this creator a subscription.
        var subscribed = 3.0
        /// You have bought a set from them before.
        var boughtBefore = 2.0
        /// You follow them but have never paid.
        var following = 1.2
        /// Free post from someone you don't already pay — the discovery path.
        var freeDiscovery = 1.0
        /// Locked post from a creator you've never opened anything of. A cold ask.
        var coldAsk = -1.5
        /// Already opened. Pushed down, never hidden.
        var seenMultiplier = 0.35
        /// A set you bought outright. Reachable, but it isn't news.
        var ownedMultiplier = 0.6
        static let `default` = Weights()
    }

    static func score(_ post: CreatorPost, context ctx: FeedContext, weights w: Weights = .default, now: Date = .now) -> Double {
        var s = 0.0

        // Freshness: linear decay, floored at zero. An old post never goes negative, it just stops
        // being news — that's what keeps a creator's back catalogue reachable.
        let ageDays = max(0, now.timeIntervalSince(post.createdAt) / 86400)
        s += max(0, w.freshness * (1 - ageDays / w.freshDays))

        // Who this is to the viewer. These don't stack: the strongest true one wins, because someone
        // who subscribes *and* follows isn't twice as interested.
        let mine = post.creatorID == ctx.me
        if !mine {
            if ctx.subscribedTo.contains(post.creatorID) { s += w.subscribed }
            else if ctx.boughtFrom.contains(post.creatorID) { s += w.boughtBefore }
            else if ctx.following.contains(post.creatorID) { s += w.following }
        }

        // A stranger's post: free work earns a look, a locked one has to wait its turn.
        let known = mine || ctx.subscribedTo.contains(post.creatorID) || ctx.boughtFrom.contains(post.creatorID) || ctx.following.contains(post.creatorID)
        if !known {
            if !post.isLocked { s += w.freeDiscovery }
            else if !ctx.openedFreeFrom.contains(post.creatorID) { s += w.coldAsk }
        }

        if ctx.seen.contains(post.id) { s *= w.seenMultiplier }
        // A set the viewer bought outright is their library, not their feed. A subscribers-only post
        // from a creator they subscribe to is not "owned" in this sense — it is the thing they pay
        // monthly to be shown, so it keeps its full score.
        if let setID = post.setID, ctx.purchasedSets.contains(setID) { s *= w.ownedMultiplier }
        return s
    }

    /// Ranked, then spread so no creator takes consecutive slots while another has something to show.
    static func rank(_ posts: [CreatorPost], context: FeedContext, weights: Weights = .default, now: Date = .now) -> [CreatorPost] {
        let scored = posts
            .map { (post: $0, score: score($0, context: context, weights: weights, now: now)) }
            .sorted { $0.score == $1.score ? $0.post.createdAt > $1.post.createdAt : $0.score > $1.score }
        return spread(scored.map(\.post))
    }

    /// One pass: if the next post shares a creator with the one just placed, look ahead for the best
    /// post by someone else and take that instead. Order is otherwise untouched, so a creator who is
    /// genuinely the most relevant still leads — they just don't lead twice running.
    static func spread(_ posts: [CreatorPost]) -> [CreatorPost] {
        var pool = posts, out: [CreatorPost] = []
        out.reserveCapacity(pool.count)
        while !pool.isEmpty {
            var index = 0
            if let last = out.last?.creatorID, pool[0].creatorID == last,
               let other = pool.firstIndex(where: { $0.creatorID != last }) {
                index = other
            }
            out.append(pool.remove(at: index))
        }
        return out
    }
}
