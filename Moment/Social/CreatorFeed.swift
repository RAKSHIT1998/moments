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
