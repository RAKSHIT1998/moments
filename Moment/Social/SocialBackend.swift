import Foundation

/// The backend seam. `CloudKitBackend` is the production implementation; `InMemoryBackend`
/// (DEBUG) drives tests and the simulator. Nothing in the UI talks to CloudKit directly.
protocol SocialBackend: AnyObject, Sendable {
    var name: String { get }

    // Identity
    func accountStatus() async -> AccountStatus
    func currentUser() async throws -> SocialUser
    func updateProfile(displayName: String, handle: String, bio: String, avatar: Data?) async throws -> SocialUser
    func user(id: String) async throws -> SocialUser
    func searchUsers(_ query: String) async throws -> [SocialUser]

    // Moments
    func createMoment(_ draft: MomentDraft) async throws -> SocialMoment
    func updateMoment(_ moment: SocialMoment) async throws -> SocialMoment
    func deleteMoment(id: String) async throws
    func moment(id: String) async throws -> SocialMoment
    func myMoments(cursor: String?) async throws -> FeedPage<SocialMoment>
    func sharedWithMe(cursor: String?) async throws -> FeedPage<SocialMoment>
    func contributions(momentID: String) async throws -> [Contribution]
    func addContribution(_ c: Contribution, mediaData: Data?) async throws -> Contribution
    func removeContribution(id: String, momentID: String) async throws
    /// Produces (or returns) the real share link and adds the members. Owner only.
    func share(momentID: String, with userIDs: [String]) async throws -> URL
    /// Accept an invitation link (opened from Messages/AirDrop/web). Returns the joined Moment.
    func acceptInvite(url: URL) async throws -> SocialMoment
    func leaveMoment(id: String) async throws
    /// Owner picks any photo as the cover.
    func setCover(momentID: String, data: Data) async throws -> SocialMoment
    /// Join a Moment you can see (public / friends / live) without an invite — "I WAS THERE".
    func join(momentID: String) async throws -> SocialMoment
    /// Owner merges another of their Moments into this one; contributions move, the source is deleted.
    func merge(sourceID: String, into targetID: String) async throws -> SocialMoment

    // Feed / discover
    func feed(cursor: String?) async throws -> FeedPage<SocialMoment>
    func discover(query: String?, place: String?, cursor: String?) async throws -> FeedPage<SocialMoment>
    /// Public Moments within `radiusKm` of a point. The point is the caller's — it is never stored.
    func nearby(latitude: Double, longitude: Double, radiusKm: Double) async throws -> [SocialMoment]
    func nowNearby(latitude: Double, longitude: Double, radiusKm: Double) async throws -> [NowPost]
    /// Everything public that happened at one venue.
    func moments(atPlace placeID: String) async throws -> [SocialMoment]
    func claim(for placeID: String) async throws -> PlaceClaim?
    func saveClaim(_ c: PlaceClaim) async throws -> PlaceClaim
    func myClaims() async throws -> [PlaceClaim]

    // Engagement
    func comments(momentID: String) async throws -> [MomentComment]
    func addComment(_ c: MomentComment) async throws -> MomentComment
    func deleteComment(id: String, momentID: String) async throws
    func react(momentID: String, contributionID: String?, kind: ReactionKind?) async throws
    func myReactions(momentID: String) async throws -> [MomentReaction]

    // NOW
    func postNow(_ post: NowPost, mediaData: Data?) async throws -> NowPost
    func nowFeed() async throws -> [NowPost]
    func deleteNow(id: String) async throws
    /// Respond to "Anyone up?" — you're in.
    func joinNow(id: String) async throws -> NowPost

    // Graph & safety
    func follow(userID: String, close: Bool) async throws
    func unfollow(userID: String) async throws
    func following() async throws -> [Follow]
    func followers() async throws -> [Follow]
    func block(userID: String) async throws
    func unblock(userID: String) async throws
    func blockedUserIDs() async throws -> [String]
    func mute(userID: String) async throws
    func mutedUserIDs() async throws -> [String]
    func report(_ report: UserReport) async throws
    func safetySettings() async throws -> SafetySettings
    func updateSafetySettings(_ s: SafetySettings) async throws

    // Inbox
    func activity(cursor: String?) async throws -> FeedPage<ActivityItem>
    func invites() async throws -> [MomentInvite]
    func markActivityRead() async throws
    func conversations() async throws -> [Conversation]
    func messages(conversationID: String) async throws -> [DirectMessage]
    func send(_ message: DirectMessage, mediaData: Data?) async throws -> DirectMessage
    func conversation(with userID: String) async throws -> Conversation

    // Groups
    func groups() async throws -> [SocialGroup]
    func saveGroup(_ g: SocialGroup) async throws -> SocialGroup
    func leaveGroup(id: String) async throws

    // Collections
    func collections() async throws -> [MomentCollection]
    func saveCollection(_ c: MomentCollection) async throws -> MomentCollection
    func deleteCollection(id: String) async throws

    // Media
    func download(_ ref: MediaRef) async throws -> Data
}

enum AccountStatus: Sendable, Equatable { case available, noAccount, restricted, unknown, offline }

struct MomentDraft: Sendable, Equatable {
    var title: String
    var description: String
    var startAt: Date?
    var endAt: Date?
    var locationName: String?
    var coarsePlace: String?
    var visibility: MomentVisibility
    var templateID: String?
    var remixedFromID: String?
    var isLive: Bool = false
    var coverData: Data?
    var isTeaser: Bool = false
    /// Members to add at creation (a group's members, "Anyone up?" joiners).
    var initialMemberIDs: [String] = []
    var place: SocialPlace? = nil
}

/// Relationship strength from actual shared experience — the strongest feed signal.
/// Private to the device; never shown as a score.
struct RelationshipGraph: Sendable {
    var sharedMomentCounts: [String: Int] = [:]     // userID → moments together
    var following: Set<String> = []
    var followers: Set<String> = []
    var close: Set<String> = []
    var muted: Set<String> = []
    var blocked: Set<String> = []

    func strength(_ userID: String) -> Double {
        if blocked.contains(userID) || muted.contains(userID) { return 0 }
        var s = 0.0
        s += min(5, Double(sharedMomentCounts[userID] ?? 0)) * 0.4
        if close.contains(userID) { s += 1.5 }
        if following.contains(userID) { s += 0.8 }
        if followers.contains(userID) { s += 0.4 }
        return s
    }
}

/// Ranks the home feed: people you know and experiences you were part of first, then recency,
/// then quality (contributions, media). Never optimized for time spent; repetition is damped.
enum FeedRanker {
    struct Scored: Sendable { var moment: SocialMoment; var score: Double; var reason: String }

    static func rank(_ moments: [SocialMoment], me: String, graph: RelationshipGraph, seen: Set<String>, now: Date = .now) -> [Scored] {
        var out: [Scored] = []
        for m in moments where !graph.blocked.contains(m.creatorID) && !graph.muted.contains(m.creatorID) {
            var score = 0.0
            var reasons: [String] = []
            if m.memberIDs.contains(me) { score += 3; reasons.append("You were there") }
            let creatorStrength = graph.strength(m.creatorID)
            score += creatorStrength
            if creatorStrength >= 1.5 { reasons.append("Someone close to you") }
            let others = m.memberIDs.filter { $0 != me && $0 != m.creatorID }
            let friendMembers = others.filter { graph.strength($0) > 0.5 }.count
            if friendMembers > 0 { score += min(2, Double(friendMembers) * 0.5); reasons.append("\(friendMembers) \(friendMembers == 1 ? "friend was" : "friends were") there") }
            let ageHours = max(0, now.timeIntervalSince(m.createdAt) / 3600)
            score += max(0, 2.5 - ageHours / 24)                       // freshness over ~2.5 days
            score += min(1.5, Double(m.contributionCount) * 0.15)      // richness
            score += min(0.5, Double(m.commentCount) * 0.05)
            if m.isLive { score += 1.5; reasons.append("Live now") }
            if seen.contains(m.id) { score *= 0.5 }                    // don't repeat
            if m.visibility == .publicAll, creatorStrength == 0 { score *= 0.6 }
            if reasons.isEmpty { reasons.append(m.visibility == .publicAll ? "Public" : "New") }
            out.append(Scored(moment: m, score: score, reason: reasons.prefix(2).joined(separator: " · ")))
        }
        return out.sorted { $0.score > $1.score }
    }
}

/// Groups a Moment's contributions into a timeline by real timestamps. Never invents narrative.
enum MomentTimeline {
    struct Entry: Sendable, Equatable, Identifiable {
        var id: String { "\(time.timeIntervalSince1970)" }
        var time: Date
        var contributions: [Contribution]
        var label: String { time.formatted(date: .omitted, time: .shortened) }
    }

    static func build(_ contributions: [Contribution], gapMinutes: Double = 45) -> [Entry] {
        let sorted = contributions.sorted { ($0.originalTimestamp ?? $0.createdAt) < ($1.originalTimestamp ?? $1.createdAt) }
        var entries: [Entry] = []
        for c in sorted {
            let t = c.originalTimestamp ?? c.createdAt
            if var last = entries.last, t.timeIntervalSince(last.time) < gapMinutes * 60, let first = last.contributions.first, t.timeIntervalSince(first.originalTimestamp ?? first.createdAt) < gapMinutes * 60 * 3 {
                last.contributions.append(c); entries[entries.count - 1] = last
            } else {
                entries.append(Entry(time: t, contributions: [c]))
            }
        }
        return entries
    }
}

/// Client-side moderation baseline. Public content also goes through the backend's report queue;
/// this only stops the obvious before it leaves the device.
enum ContentModeration {
    static let blockedPatterns: [String] = [
        #"\b(kill yourself|kys)\b"#, #"\b(n[i1]gg(a|er)s?)\b"#, #"\b(f[a@]g(got)?s?)\b"#, #"\b(rape (you|her|him))\b"#
    ]
    static let spamPatterns: [String] = [#"(https?://\S+\s*){3,}"#, #"\b(free (crypto|bitcoin|followers)|dm for (promo|collab)|earn \$?\d{3,} (a|per) day)\b"#]

    enum Verdict: Equatable { case ok, blocked(String), spam }

    static func check(_ text: String) -> Verdict {
        for p in blockedPatterns where text.matches(p) { return .blocked("That message contains language we don't allow.") }
        for p in spamPatterns where text.matches(p) { return .spam }
        return .ok
    }
}
