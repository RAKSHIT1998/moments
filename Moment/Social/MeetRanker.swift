import Foundation

/// Who to show, and why. Pure: Moments, places, rituals, NOW → overlaps. No inferred attraction, no hidden score.
enum MeetRanker {
    struct Candidate: Identifiable, Equatable {
        var profile: DatingProfile
        var overlaps: [MeetOverlap]
        var id: String { profile.userID }
        var score: Double { overlaps.reduce(0) { $0 + $1.weight } }
    }

    /// Everything two people have actually shared.
    static func overlaps(me: String, other: String, moments: [SocialMoment], nows: [NowPost], now: Date = .now) -> [MeetOverlap] {
        var out: [MeetOverlap] = []
        let mine = moments.filter { $0.memberIDs.contains(me) }
        let theirs = moments.filter { $0.memberIDs.contains(other) }
        for m in mine where m.memberIDs.contains(other) { out.append(MeetOverlap(kind: .sharedMoment, label: "Both at \(m.title)", momentID: m.id)) }
        // Same venue within 30 days, but not the same Moment (already counted).
        let recent = { (m: SocialMoment) in (m.startAt ?? m.createdAt) > now.addingTimeInterval(-30 * 86400) }
        var places = Set<String>()
        for a in mine.filter(recent) { for b in theirs.filter(recent) where a.id != b.id && !b.memberIDs.contains(me) {
            if let pa = a.place?.id, pa == b.place?.id, places.insert(pa).inserted { out.append(MeetOverlap(kind: .samePlace, label: "Both at \(a.place!.name) this month", momentID: b.id)) }
        } }
        // Same ritual series (title + creator) even in different weeks.
        var rituals = Set<String>()
        for a in mine where Rituals.isRitual(a) { for b in theirs where Rituals.isRitual(b) && a.creatorID == b.creatorID && a.title.lowercased() == b.title.lowercased() && a.id != b.id {
            if rituals.insert(a.title.lowercased()).inserted { out.append(MeetOverlap(kind: .sameRitual, label: "You both go to \(a.title)", momentID: b.id)) }
        } }
        if let n = nows.first(where: { $0.authorID == other && !$0.isExpired && $0.isStatus }) { out.append(MeetOverlap(kind: .nearbyNow, label: "\(n.authorName.split(separator: " ").first.map(String.init) ?? "They") \(n.activity.line) right now", momentID: nil)) }
        return out
    }

    /// Filters by each side's preferences and the viewer's history, then ranks by overlap.
    static func rank(me: DatingProfile, candidates: [DatingProfile], moments: [SocialMoment], nows: [NowPost], known: Set<String>, passed: Set<String>, liked: Set<String>, blocked: Set<String>, now: Date = .now) -> [Candidate] {
        var out: [Candidate] = []
        for c in candidates where c.userID != me.userID && !passed.contains(c.userID) && !liked.contains(c.userID) && !blocked.contains(c.userID) {
            guard c.age >= 18, me.age >= 18 else { continue }
            guard me.seeking.contains(c.gender), c.seeking.contains(me.gender) else { continue }
            if c.hideFromKnown && known.contains(c.userID) { continue }
            if me.hideFromKnown && known.contains(c.userID) { continue }
            let o = overlaps(me: me.userID, other: c.userID, moments: moments, nows: nows, now: now)
            if o.isEmpty && (c.overlapOnly || me.overlapOnly) { continue }
            out.append(Candidate(profile: c, overlaps: o))
        }
        return out.sorted { ($0.score, $0.profile.updatedAt) > ($1.score, $1.profile.updatedAt) }
    }

    /// Mutual likes become matches. Deterministic id so both phones agree without talking.
    static func matches(me: String, sent: [DatingLike], received: [DatingLike], names: [String: String], overlapsFor: (String) -> [MeetOverlap]) -> [MeetMatch] {
        let likedMe = Dictionary(grouping: received, by: \.fromID)
        var out: [MeetMatch] = []
        for l in sent { if let theirs = likedMe[l.toID]?.first {
            let ids = [me, l.toID].sorted()
            out.append(MeetMatch(id: "match_" + ids.joined(separator: "_"), userIDs: ids, names: ids.map { names[$0] ?? ($0 == l.toID ? theirs.fromName : "You") }, overlaps: overlapsFor(l.toID), conversationID: nil, createdAt: max(l.createdAt, theirs.createdAt)))
        } }
        return out.sorted { $0.createdAt > $1.createdAt }
    }
}
