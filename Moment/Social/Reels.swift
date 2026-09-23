import Foundation

/// Reels are the video posts creators publish: full-screen, autoplaying, one per screen.
/// A locked one shows its cover behind the blur with the price on it — the video itself is never
/// sent to anyone who hasn't paid, so there is nothing to leak.
struct Reel: Identifiable, Sendable, Equatable {
    var id: String
    var setID: String
    var creatorID: String
    var creatorName: String
    var title: String
    var blurb: String
    /// The playable clip. Nil when the set is locked: only the cover exists on this device.
    var video: MediaRef?
    var cover: MediaRef?
    var createdAt: Date
    var gate: CreatorPost.Gate
    var isLocked: Bool { gate != .open }
}

enum ReelBuilder {
    /// Every video post the viewer could watch or buy, newest first. Free and already-bought ones first
    /// when they're equally fresh, because a reel that plays is worth more than a wall.
    static func build(sets: [VaultSet], items: (String) -> [VaultItem], plans: [String: CreatorPlan], purchases: Set<String>, subscribedTo: Set<String>, me: String, blocked: Set<String> = [], seen: Set<String> = [], now: Date = .now) -> [Reel] {
        var out: [Reel] = []
        for set in sets where set.isVideo && set.visible && !blocked.contains(set.creatorID) {
            let mine = set.creatorID == me
            let open = mine || set.isFree || purchases.contains(set.id) || subscribedTo.contains(set.creatorID)
            let gate: CreatorPost.Gate = open ? .open : .buy(priceMinor: set.priceMinor, currency: set.currency)
            let clips = open ? items(set.id).filter { $0.kind == .video && $0.media != nil } : []
            // One reel per clip when it's open; one locked card per set otherwise.
            if open && !clips.isEmpty {
                for (i, clip) in clips.enumerated() {
                    out.append(Reel(id: "\(set.id)#\(i)", setID: set.id, creatorID: set.creatorID, creatorName: set.creatorName, title: set.title, blurb: clip.caption.isEmpty ? set.blurb : clip.caption, video: clip.media, cover: set.cover, createdAt: set.createdAt, gate: .open))
                }
            } else if !open {
                out.append(Reel(id: set.id, setID: set.id, creatorID: set.creatorID, creatorName: set.creatorName, title: set.title, blurb: set.blurb, video: nil, cover: set.cover, createdAt: set.createdAt, gate: gate))
            }
        }
        _ = plans
        return out.sorted { a, b in
            let sa = score(a, seen: seen, now: now), sb = score(b, seen: seen, now: now)
            return sa == sb ? a.createdAt > b.createdAt : sa > sb
        }
    }

    static func score(_ r: Reel, seen: Set<String>, now: Date) -> Double {
        var s = max(0, 2.5 - now.timeIntervalSince(r.createdAt) / 86400)   // freshness over ~2.5 days
        if !r.isLocked { s += 1 }
        if seen.contains(r.id) { s *= 0.4 }
        return s
    }
}
