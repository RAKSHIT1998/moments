import Foundation

// The social primitive: an experience shared by the people who were there.
// These are plain value types that cross the backend boundary; CloudKit records map to them.

struct SocialUser: Codable, Sendable, Equatable, Identifiable, Hashable {
    var id: String                // backend user id (CloudKit user record name)
    var displayName: String
    var handle: String            // unique, lowercase, no @
    var bio: String
    var avatarRef: MediaRef?
    var isPrivateAccount: Bool
    var momentCount: Int
    var sharedCount: Int
    var placeCount: Int
    var peopleCount: Int
    var createdAt: Date
    /// Curve25519 public key (base64) + its fingerprint — the person's MOMENT ID. Lets anyone verify signatures.
    var publicKey: String? = nil
    var momentID: String? = nil
}

/// A pointer to a media file: a local file for pending uploads, a backend asset once uploaded.
struct MediaRef: Codable, Sendable, Equatable, Hashable {
    enum Kind: String, Codable, Sendable { case photo, video, voice }
    var kind: Kind
    /// Local relative path in the media store (always present once downloaded/created).
    var localRef: String?
    /// Backend asset identifier (CKAsset record name + field), nil while pending.
    var remoteID: String?
    var width: Int?
    var height: Int?
    var durationSeconds: Double?
}

enum MomentVisibility: String, Codable, CaseIterable, Sendable {
    case privateOnly, closeFriends, friends, group, publicAll
    var label: String {
        switch self {
        case .privateOnly: "Private"; case .closeFriends: "Close friends"; case .friends: "Friends"; case .group: "People in it"; case .publicAll: "Public"
        }
    }
    var symbol: String {
        switch self {
        case .privateOnly: "lock"; case .closeFriends: "star"; case .friends: "person.2"; case .group: "person.3"; case .publicAll: "globe"
        }
    }
    var explanation: String {
        switch self {
        case .privateOnly: "Only you. Contributors you invite can still add to it."
        case .closeFriends: "People you mark as close friends."
        case .friends: "People you follow who follow you back."
        case .group: "Only the people who are part of this Moment."
        case .publicAll: "Anyone can find it in Discover and remix it."
        }
    }
}

/// A venue or area: a café, a beach, a club, a city. Venue coordinates are public knowledge;
/// a person's own location never leaves the device — it is only used to ask "what's near me?".
struct SocialPlace: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: String
    var name: String
    /// Neighbourhood / city line shown under the name ("Bandra West, Mumbai").
    var area: String
    var latitude: Double
    var longitude: Double
    var category: String?

    /// Stable id from name + rounded coordinates, so the same café from two phones is one place.
    static func makeID(name: String, latitude: Double, longitude: Double) -> String {
        let n = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return "\(n)_\(Int((latitude * 1000).rounded()))_\(Int((longitude * 1000).rounded()))"
    }

    func distance(fromLatitude lat: Double, longitude lon: Double) -> Double {
        let r = 6371.0, dLat = (latitude - lat) * .pi / 180, dLon = (longitude - lon) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat * .pi / 180) * cos(latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))   // km
    }
}

/// A venue owner's claim on a place page. Claims are honest about their state: `verified` is only
/// set by review, never by the app. One claim per place.
struct PlaceClaim: Codable, Sendable, Equatable, Identifiable, Hashable {
    var id: String            // == placeID
    var placeID: String
    var ownerID: String
    var ownerName: String
    var businessName: String
    var role: String          // owner / manager / staff
    var note: String          // pinned welcome line on the place page
    var verified: Bool
    var createdAt: Date
}

struct SocialMoment: Codable, Sendable, Equatable, Identifiable, Hashable {
    var id: String
    var creatorID: String
    var creatorName: String
    var title: String
    var description: String
    var coverRef: MediaRef?
    var createdAt: Date
    var startAt: Date?
    var endAt: Date?
    var locationName: String?
    /// Coarse (city-level) for Discover; never a precise coordinate.
    var coarsePlace: String?
    var visibility: MomentVisibility
    var memberIDs: [String]
    var memberNames: [String]
    var contributionCount: Int
    var mediaCount: Int
    var commentCount: Int
    var reactionCounts: [String: Int]
    var shareCount: Int
    var isLive: Bool
    var templateID: String?
    var remixedFromID: String?
    /// Real deep link (CloudKit share URL) once the Moment has been shared with people.
    var shareURL: URL?
    /// Contributors may remove their own media; owner can turn resharing/downloads off.
    var allowsReshare: Bool
    var allowsDownload: Bool
    var allowsContributions: Bool
    /// "You had to be there": shown blurred until the viewer taps Reveal. Playful, opt-in.
    var isTeaser: Bool = false
    /// The venue this happened at, when the creator picked one.
    var place: SocialPlace? = nil
    /// Creator's signature over (id, creator, title, createdAt) — proves who made it and that it wasn't altered.
    var signature: String? = nil
    var creatorPublicKey: String? = nil
    var signedAt: Date? = nil

    var isGroup: Bool { memberIDs.count > 1 }
    var dateLabel: String {
        guard let s = startAt else { return createdAt.formatted(.dateTime.month(.abbreviated).day().year()) }
        if let e = endAt, !Calendar.current.isDate(s, inSameDayAs: e) { return "\(s.formatted(.dateTime.month(.abbreviated).day()))–\(e.formatted(.dateTime.day()))" }
        return s.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

struct Contribution: Codable, Sendable, Equatable, Identifiable, Hashable {
    enum Kind: String, Codable, Sendable { case photo, video, voice, text }
    var id: String
    var momentID: String
    var authorID: String
    var authorName: String
    var kind: Kind
    var media: MediaRef?
    var caption: String
    var createdAt: Date
    /// When the media was actually captured (EXIF), used for the timeline.
    var originalTimestamp: Date?
    var reactionCounts: [String: Int]
    var commentCount: Int
    var uploadState: UploadState

    enum UploadState: String, Codable, Sendable { case pending, uploading, uploaded, failed }
}

struct MomentComment: Codable, Sendable, Equatable, Identifiable, Hashable {
    var id: String
    var momentID: String
    var contributionID: String?
    var authorID: String
    var authorName: String
    var text: String
    var createdAt: Date
}

struct MomentReaction: Codable, Sendable, Equatable, Identifiable, Hashable {
    var id: String
    var momentID: String
    var contributionID: String?
    var authorID: String
    var kind: ReactionKind
    var createdAt: Date
}

enum ReactionKind: String, Codable, CaseIterable, Sendable {
    case like, core, forgot, unreal, neverForget, why, love, another
    var emoji: String {
        switch self { case .like: "👍"; case .core: "❤️"; case .forgot: "😂"; case .unreal: "🔥"; case .neverForget: "😭"; case .why: "💀"; case .love: "🫶"; case .another: "📸" }
    }
    var label: String {
        switch self { case .like: "Like"; case .core: "Core memory"; case .forgot: "I forgot this"; case .unreal: "Unreal"; case .neverForget: "Never forget"; case .why: "Why"; case .love: "Love this"; case .another: "I have another one" }
    }
}

/// NOW: what's happening right now. Gone in 24 hours unless saved to a Moment.
struct NowPost: Codable, Sendable, Equatable, Identifiable, Hashable {
    /// What you're up to — "Anyone up?" presets. `none` is a plain post.
    enum Activity: String, Codable, CaseIterable, Sendable {
        case none, drinks, food, drive, coffee, gym, party, shopping, beach, movie, exploring, chilling
        var emoji: String {
            switch self { case .none: ""; case .drinks: "🍸"; case .food: "🍜"; case .drive: "🚗"; case .coffee: "☕️"; case .gym: "🏋️"; case .party: "🎉"; case .shopping: "🛍️"; case .beach: "🏖️"; case .movie: "🎬"; case .exploring: "🧭"; case .chilling: "🛋️" }
        }
        var label: String { self == .none ? "Just a post" : rawValue.capitalizedFirst }
        var line: String {
            switch self { case .none: ""; case .drinks: "is out for drinks"; case .food: "is looking for food"; case .drive: "is on a drive"; case .coffee: "wants coffee"; case .gym: "is at the gym"; case .party: "is at a party"; case .shopping: "is shopping"; case .beach: "is at the beach"; case .movie: "is watching a movie"; case .exploring: "is exploring"; case .chilling: "is chilling" }
        }
    }
    var id: String
    var authorID: String
    var authorName: String
    var text: String
    var media: MediaRef?
    var createdAt: Date
    var expiresAt: Date
    var coarsePlace: String?
    var savedToMomentID: String?
    var activity: Activity = .none
    var place: SocialPlace? = nil
    /// People who tapped JOIN (ids) — the spontaneous-meetup mechanic.
    var joinerIDs: [String] = []
    var joinerNames: [String] = []
    /// Author opted in to being found by people nearby (mesh/relay routing hint).
    var discoverable: Bool = false
    var isExpired: Bool { expiresAt < .now }
    var isStatus: Bool { activity != .none }
}

/// A permanent group: the boys, family, work, travel crew. Has its own Moments, NOW and chat.
struct SocialGroup: Codable, Sendable, Equatable, Identifiable, Hashable {
    var id: String
    var ownerID: String
    var name: String
    var emoji: String
    var memberIDs: [String]
    var memberNames: [String]
    var conversationID: String?
    var createdAt: Date
}

struct Follow: Codable, Sendable, Equatable, Hashable {
    var fromID: String
    var toID: String
    var createdAt: Date
    var isClose: Bool
}

struct MomentInvite: Codable, Sendable, Equatable, Identifiable, Hashable {
    var id: String
    var momentID: String
    var momentTitle: String
    var inviterID: String
    var inviterName: String
    var shareURL: URL?
    var createdAt: Date
    var accepted: Bool
}

struct Conversation: Codable, Sendable, Equatable, Identifiable, Hashable {
    var id: String
    var participantIDs: [String]
    var participantNames: [String]
    var lastMessage: String
    var updatedAt: Date
}

struct DirectMessage: Codable, Sendable, Equatable, Identifiable, Hashable {
    var id: String
    var conversationID: String
    var authorID: String
    var authorName: String
    var text: String
    var media: MediaRef?
    var momentID: String?
    var createdAt: Date
}

struct ActivityItem: Codable, Sendable, Equatable, Identifiable, Hashable {
    enum Kind: String, Codable, Sendable { case invite, contribution, reaction, comment, follow, joined }
    var id: String
    var kind: Kind
    var actorName: String
    var momentID: String?
    var momentTitle: String?
    var text: String
    var createdAt: Date
    var read: Bool
}

struct UserReport: Codable, Sendable, Equatable, Identifiable {
    enum Reason: String, Codable, CaseIterable, Sendable {
        case spam, harassment, sexual, violence, hate, scam, impersonation, copyright, other
        var label: String { rawValue.capitalizedFirst }
    }
    var id: String
    var reporterID: String
    var targetUserID: String?
    var targetMomentID: String?
    var targetContributionID: String?
    var targetCommentID: String?
    var reason: Reason
    var details: String
    var createdAt: Date
}

/// Privacy controls every account has from day one.
struct SafetySettings: Codable, Sendable, Equatable {
    enum Audience: String, Codable, CaseIterable, Sendable { case everyone, friends, nobody
        var label: String { rawValue.capitalized }
    }
    var privateAccount = false
    var whoCanAddMeToMoments: Audience = .friends
    var whoCanComment: Audience = .friends
    var whoCanMessage: Audience = .friends
    var whoCanMention: Audience = .everyone
    var allowDiscoverByLocation = false
}

/// A user-made album of Moments ("Goa trips", "2026"). Private to its owner.
struct MomentCollection: Codable, Sendable, Equatable, Identifiable, Hashable {
    var id: String
    var ownerID: String
    var title: String
    var emoji: String
    var momentIDs: [String]
    var createdAt: Date
}

struct FeedPage<T: Sendable>: Sendable {
    var items: [T]
    var cursor: String?
}

enum SocialError: Error, LocalizedError, Sendable {
    case notSignedIn, offline, notFound, notAllowed, blocked, quotaExceeded, backend(String)
    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to iCloud on this iPhone to use Moments with other people."
        case .offline: "You're offline. Your Moments are still here; uploads will resume."
        case .notFound: "That Moment isn't available anymore."
        case .notAllowed: "You don't have permission to do that."
        case .blocked: "You can't interact with this person."
        case .quotaExceeded: "iCloud storage is full."
        case .backend(let m): m
        }
    }
}
