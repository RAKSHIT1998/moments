import Foundation

/// Reels, the MOMENT way: a reel is a night, not a post. Either someone's video side, or the whole
/// Moment auto-cut from everyone's sides in order. Every reel names who was there and lets you step in.
struct Reel: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case video(Contribution)          // a real video someone added
        case cut([Contribution])          // everyone's sides, in time order
    }
    var id: String
    var momentID: String
    var kind: Kind
    var title: String
    var creatorID: String
    var creatorName: String
    var memberNames: [String]
    var memberIDs: [String]
    var place: SocialPlace?
    var coarsePlace: String?
    var createdAt: Date
    var isLive: Bool
    var contributionCount: Int
    var commentCount: Int
    var reactionCount: Int
    /// A cut updates itself as people add sides — that's the reason to come back.
    var isCut: Bool { if case .cut = kind { return true }; return false }
    var sides: [Contribution] { switch kind { case .video(let c): [c]; case .cut(let cs): cs } }
    var authorLine: String {
        guard isCut else { return creatorName }
        let n = memberIDs.count
        return n <= 1 ? creatorName : "\(creatorName) + \(n - 1)"
    }
}

enum ReelBuilder {
    /// Which Moments become reels, and in what order. Fresh and live first, then the ones with the most
    /// material. Locked/teaser Moments never become reels — a reel shows what's inside.
    static func build(moments: [SocialMoment], sides: (String) -> [Contribution], me: String, seen: Set<String> = [], now: Date = .now) -> [Reel] {
        var out: [Reel] = []
        for m in moments where !m.isLocked && !(m.isTeaser && !m.memberIDs.contains(me)) {
            let all = sides(m.id).filter { $0.uploadState == .uploaded }.sorted { ($0.originalTimestamp ?? $0.createdAt) < ($1.originalTimestamp ?? $1.createdAt) }
            // Every video side is its own reel.
            for v in all where v.kind == .video && v.media != nil {
                out.append(reel(id: "v_" + v.id, moment: m, kind: .video(v), createdAt: v.originalTimestamp ?? v.createdAt))
            }
            // The night itself, when there's enough to cut: at least three visual sides.
            let visual = all.filter { ($0.kind == .photo || $0.kind == .video) && $0.media != nil }
            if visual.count >= 3 {
                out.append(reel(id: "c_" + m.id, moment: m, kind: .cut(Array(visual.prefix(12))), createdAt: m.startAt ?? m.createdAt))
            }
        }
        return out.sorted { a, b in
            let sa = score(a, me: me, seen: seen, now: now), sb = score(b, me: me, seen: seen, now: now)
            return sa == sb ? a.createdAt > b.createdAt : sa > sb
        }
    }

    private static func reel(id: String, moment m: SocialMoment, kind: Reel.Kind, createdAt: Date) -> Reel {
        Reel(id: id, momentID: m.id, kind: kind, title: m.title, creatorID: m.creatorID, creatorName: m.creatorName, memberNames: m.memberNames, memberIDs: m.memberIDs, place: m.place, coarsePlace: m.coarsePlace, createdAt: createdAt, isLive: m.isLive, contributionCount: m.contributionCount, commentCount: m.commentCount, reactionCount: m.reactionCounts.values.reduce(0, +))
    }

    /// No engagement bait: being in it, being live, being recent and having many people's sides is all that counts.
    static func score(_ r: Reel, me: String, seen: Set<String>, now: Date) -> Double {
        var s = 0.0
        if r.memberIDs.contains(me) { s += 3 }
        if r.isLive { s += 2 }
        let ageHours = max(0, now.timeIntervalSince(r.createdAt) / 3600)
        s += max(0, 2.5 - ageHours / 24)
        s += min(2, Double(Set(r.sides.map(\.authorID)).count) * 0.5)   // more people in the cut = better
        if case .video = r.kind { s += 0.5 }                            // a real video is a real reel
        if seen.contains(r.id) { s *= 0.4 }
        return s
    }
}
