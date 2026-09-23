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
    case privateOnly, closeFriends, friends, group, publicAll, subscribers
    var label: String {
        switch self {
        case .privateOnly: "Private"; case .closeFriends: "Close friends"; case .friends: "Friends"; case .group: "People in it"; case .publicAll: "Public"; case .subscribers: "Subscribers"
        }
    }
    var symbol: String {
        switch self {
        case .privateOnly: "lock"; case .closeFriends: "star"; case .friends: "person.2"; case .group: "person.3"; case .publicAll: "globe"; case .subscribers: "crown"
        }
    }
    var explanation: String {
        switch self {
        case .privateOnly: "Only you. Contributors you invite can still add to it."
        case .closeFriends: "People you mark as close friends."
        case .friends: "People you follow who follow you back."
        case .group: "Only the people who are part of this Moment."
        case .publicAll: "Anyone can find it in Discover and remix it."
        case .subscribers: "Paying subscribers only. Everyone else sees a locked preview."
        }
    }
    /// Sold content: the creator earns from it.
    var isPaid: Bool { self == .subscribers }
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
    /// Set by the backend for the viewer: a subscribers-only Moment they haven't paid for. Cover shows, nothing else.
    var isLocked: Bool = false

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
    /// Group chats carry the group's name/emoji; 1:1 chats leave these nil.
    var title: String? = nil
    var emoji: String? = nil
    var groupID: String? = nil
    var isGroup: Bool { participantIDs.count > 2 || groupID != nil }
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
    /// Quote-reply to another message in the thread.
    var replyToID: String? = nil
    /// Pay-per-view: a set (usually one photo, hidden from the shop) that this message unlocks.
    /// The media itself never travels in the message — only the set id and its price.
    var vaultSetID: String? = nil
    var priceMinor: Int = 0
    var currency: String = "INR"
    var isPayPerView: Bool { vaultSetID != nil && priceMinor > 0 }
    /// A single-emoji message with `replyToID` set is a reaction: shown under the target, not as a bubble.
    var isReaction: Bool { replyToID != nil && text.count <= 2 && text.unicodeScalars.allSatisfy { $0.properties.isEmoji } && !text.isEmpty && media == nil && momentID == nil }
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

// MARK: - Creator economy

/// What a creator sells: one plan per creator, priced at a fixed tier (App Store products), 30 days at a time.
/// One subscription per creator, at the price they choose. 30 days at a time, no auto-renew.
struct CreatorPlan: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Apple sells fixed price points, so a card-rail price has to be mapped to the nearest product.
    /// This is only that mapping — it is never what the creator "picked".
    enum Tier: String, Codable, CaseIterable, Sendable {
        case t1, t2, t3
        var productID: String { "creator.30d.\(rawValue)" }
        var fallbackPrice: String { switch self { case .t1: "₹199"; case .t2: "₹499"; case .t3: "₹999" } }
        var label: String { switch self { case .t1: "Starter"; case .t2: "Standard"; case .t3: "Premium" } }
        var referenceAmount: Double { switch self { case .t1: 199; case .t2: 499; case .t3: 999 } }
        /// The closest App Store product to a price the creator set.
        static func nearest(toMinor minor: Int) -> Tier {
            let amount = Double(minor) / 100
            return allCases.min { abs($0.referenceAmount - amount) < abs($1.referenceAmount - amount) } ?? .t1
        }
    }
    var id: String { creatorID }
    var creatorID: String
    var creatorName: String
    var title: String
    var pitch: String
    /// What the creator charges for 30 days, in minor units of `currency`. This is the real price.
    var priceMinor: Int
    var currency: String
    var perks: [String]
    /// How the creator wants to be paid (UPI / PayPal / IBAN). Read only by the payouts process.
    var payoutHint: String
    var createdAt: Date
    /// Longer commitments at a discount the creator sets. Empty means monthly only.
    var bundles: [Bundle] = []
    /// An optional, public tip goal: "₹40,000 for the new lens". Progress is real tips, never inflated.
    var goalTitle: String = ""
    var goalAmountMinor: Int = 0
    /// Only used when the purchase has to go through Apple.
    var tier: Tier { Tier.nearest(toMinor: priceMinor) }

    /// N months for a percentage off the monthly price.
    struct Bundle: Codable, Sendable, Equatable, Hashable, Identifiable {
        var months: Int
        var discountPercent: Int
        var id: Int { months }
        func totalMinor(monthly: Int) -> Int { Int((Double(monthly * months) * (1 - Double(discountPercent) / 100)).rounded()) }
        func perMonthMinor(monthly: Int) -> Int { totalMinor(monthly: monthly) / max(1, months) }
        var label: String { months == 1 ? "1 month" : "\(months) months" }
    }
    func bundleLabel(_ b: Bundle, locale: Locale = .current) -> String {
        (Double(b.totalMinor(monthly: priceMinor)) / 100).formatted(.currency(code: currency).locale(locale).precision(.fractionLength(0)))
    }
    func priceLabel(_ locale: Locale = .current) -> String { (Double(priceMinor) / 100).formatted(.currency(code: currency).locale(locale).precision(.fractionLength(0))) }
}

struct CreatorSubscription: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: String
    var subscriberID: String
    var subscriberName: String
    var creatorID: String
    var tier: CreatorPlan.Tier
    var startedAt: Date
    var expiresAt: Date
    /// App Store transaction id; nil only for test/demo grants.
    var transactionID: String?
    var isActive: Bool { expiresAt > .now }
}

/// A one-off thank-you on a Moment. Consumable App Store products; the creator gets the same share as subscriptions.
struct CreatorTip: Codable, Sendable, Equatable, Hashable, Identifiable {
    enum Amount: String, Codable, CaseIterable, Sendable {
        case small, medium, large
        var productID: String { "creator.tip.\(rawValue)" }
        var fallbackPrice: String { switch self { case .small: "₹49"; case .medium: "₹99"; case .large: "₹499" } }
        var referenceAmount: Double { switch self { case .small: 49; case .medium: 99; case .large: 499 } }
        var emoji: String { switch self { case .small: "☕️"; case .medium: "🍜"; case .large: "🎉" } }
    }
    var id: String
    var fromID: String
    var fromName: String
    var creatorID: String
    var momentID: String?
    var amount: Amount
    var note: String
    var createdAt: Date
    var transactionID: String?
}

// MARK: - Creator storefront (sets, purchases, bookings, links)

/// A set the creator sells: photos/videos they own, priced once. Free sets are how people find them.
/// Media never leaves the creator's storage unencrypted; a buyer receives a key, not a copy from us.
struct VaultSet: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: String
    var creatorID: String
    var creatorName: String
    var title: String
    var blurb: String
    /// 0 = free. Otherwise the creator's asking price in their currency, before the platform fee.
    var priceMinor: Int
    var currency: String
    /// The one image everyone can see — the creator picks it.
    var cover: MediaRef?
    var itemCount: Int
    var isVideo: Bool
    var createdAt: Date
    var visible: Bool
    /// Subscribers-only: no separate price, the subscription opens it. This is what a subscription buys.
    var subscribersOnly: Bool = false
    var isFree: Bool { priceMinor == 0 && !subscribersOnly }
    func priceLabel(_ locale: Locale = .current) -> String {
        if subscribersOnly { return "Subscribers" }
        return isFree ? "Free" : (Double(priceMinor) / 100).formatted(.currency(code: currency).locale(locale).precision(.fractionLength(0)))
    }
}

/// One photo or clip inside a set. `sealed` is the media, encrypted under the set key.
struct VaultItem: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: String
    var setID: String
    var kind: MediaRef.Kind
    var media: MediaRef?
    var caption: String
    var index: Int
}

/// Proof someone paid for a set. The key that opens it is delivered separately, sealed to them.
struct VaultPurchase: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: String
    var setID: String
    var creatorID: String
    var buyerID: String
    var buyerName: String
    var amountMinor: Int
    var currency: String
    /// How the money moved: App Store product, or a web checkout reference from the creator's processor.
    var rail: PaymentRail
    var reference: String?
    var createdAt: Date
}

enum PaymentRail: String, Codable, Sendable, CaseIterable {
    case appStore, web, none
    var label: String { switch self { case .appStore: "App Store"; case .web: "Card"; case .none: "Free" } }
}

/// Paid time: a call, a shoot, a custom. The creator sets the length, price and when they're available.
struct BookingOffer: Codable, Sendable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable { case photo, videoCall, voiceCall, meet, custom
        var label: String {
            switch self { case .photo: "A photo"; case .videoCall: "Video call"; case .voiceCall: "Voice call"; case .meet: "Meet in person"; case .custom: "Something else" }
        }
        var symbol: String {
            switch self { case .photo: "camera.fill"; case .videoCall: "video.fill"; case .voiceCall: "phone.fill"; case .meet: "figure.2"; case .custom: "sparkles" }
        }
        /// Only calls need a length; a photo or a custom doesn't.
        var hasDuration: Bool { self == .videoCall || self == .voiceCall || self == .meet }
        /// Happens inside the app, with a camera or a microphone and a clock.
        var isCall: Bool { self == .videoCall || self == .voiceCall }
        var wantsCamera: Bool { self == .videoCall }
    }
    var id: String
    var creatorID: String
    var creatorName: String
    var kind: Kind
    var minutes: Int
    var priceMinor: Int
    var currency: String
    var note: String
    var active: Bool
    func priceLabel(_ locale: Locale = .current) -> String { (Double(priceMinor) / 100).formatted(.currency(code: currency).locale(locale).precision(.fractionLength(0))) }
}

/// A request and its price. Two ways in: the fan takes something off the creator's menu (an offer, price
/// already set), or asks for something and the creator names a price for that one thing.
struct Booking: Codable, Sendable, Equatable, Hashable, Identifiable {
    enum Status: String, Codable, Sendable {
        case asked          // fan asked, no price yet
        case quoted         // creator named a price for this request
        case requested      // fan is committed at a known price, waiting on the creator
        case accepted       // creator confirmed; a room exists for calls
        case declined, done, refunded
        var label: String {
            switch self {
            case .asked: "Waiting for a price"; case .quoted: "Price offered"; case .requested: "Waiting on them"
            case .accepted: "Confirmed"; case .declined: "Declined"; case .done: "Done"; case .refunded: "Refunded"
            }
        }
        /// Money only ever moves on these.
        var isPaid: Bool { self == .accepted || self == .done }
    }
    var id: String
    var offerID: String
    var creatorID: String
    var creatorName: String
    var buyerID: String
    var buyerName: String
    var kind: BookingOffer.Kind
    var minutes: Int
    /// 0 until the creator quotes.
    var amountMinor: Int
    var currency: String
    var startsAt: Date
    var status: Status
    var note: String
    var rail: PaymentRail
    var reference: String?
    /// Room the two of them join at the time. Empty until accepted.
    var roomID: String
    var createdAt: Date
    /// When the media actually connected, and when the call ended. Both nil until it happens; these are
    /// what the receipt is built from, never the scheduled time.
    var connectedAt: Date? = nil
    var endedAt: Date? = nil
    /// Minutes bought mid-call, on top of `minutes`.
    var extraMinutes: Int = 0

    /// A call (or a meet) the two of them still owe each other time for, so the slot stays blocked.
    var holdsTime: Bool { kind.hasDuration && (status == .requested || status == .accepted) && endedAt == nil }
    /// Ready to join: confirmed, has a room, and hasn't already happened.
    var isJoinable: Bool { status == .accepted && !roomID.isEmpty && endedAt == nil && kind.isCall }
    /// The window the two of them may join in: from five minutes early until the paid time would be up.
    func joinWindow(graceMinutes: Int = 5) -> ClosedRange<Date> {
        let opens = startsAt.addingTimeInterval(-Double(graceMinutes) * 60)
        let closes = startsAt.addingTimeInterval(Double(max(1, minutes + extraMinutes) + graceMinutes) * 60)
        return opens...closes
    }
    var paidMinutes: Int { minutes + extraMinutes }
    func totalLabel(_ locale: Locale = .current) -> String {
        let per = minutes > 0 ? Double(amountMinor) / Double(minutes) : 0
        let total = Double(amountMinor) + per * Double(extraMinutes)
        return (total / 100).formatted(.currency(code: currency).locale(locale).precision(.fractionLength(0)))
    }
}

/// Where else to find the creator. Shown on their profile, verified only by them saying so.
struct CreatorLinks: Codable, Sendable, Equatable, Hashable {
    var instagram: String = ""
    var x: String = ""
    var tiktok: String = ""
    var youtube: String = ""
    var website: String = ""
    var all: [(label: String, handle: String, url: URL)] {
        var out: [(String, String, URL)] = []
        func add(_ label: String, _ raw: String, _ base: String) {
            let h = raw.trimmed.replacingOccurrences(of: "@", with: "")
            guard !h.isEmpty else { return }
            if h.hasPrefix("http"), let u = URL(string: h) { out.append((label, h, u)) }
            else if let u = URL(string: base + h) { out.append((label, "@" + h, u)) }
        }
        add("Instagram", instagram, "https://instagram.com/")
        add("X", x, "https://x.com/")
        add("TikTok", tiktok, "https://tiktok.com/@")
        add("YouTube", youtube, "https://youtube.com/@")
        add("Website", website, "https://")
        return out
    }
}

/// The split. MOMENT receives net proceeds from the App Store; creators are paid this share of that.
enum CreatorEconomics {
    /// What MOMENT keeps on its own rail (web checkout): 10%. The creator keeps the rest of what's left
    /// after their payment processor. On Apple's rail the platform can't keep 10% — Apple takes 30% first —
    /// so `creatorShare` applies there and the honest numbers differ per rail. Never quote one for the other.
    static let platformFee = 0.10
    static let creatorShare = 0.80
    static let appStoreShare = 0.30
    /// What the creator receives from a sale on a given rail, before their own processor's cut.
    static func creatorTake(_ amountMinor: Int, rail: PaymentRail) -> Double {
        let gross = Double(amountMinor) / 100
        switch rail {
        case .web: return gross * (1 - platformFee)
        case .appStore: return gross * (1 - appStoreShare) * creatorShare
        case .none: return 0
        }
    }
    static func creatorEstimate(_ subs: [CreatorSubscription], tips: [CreatorTip] = [], sales: [VaultPurchase] = [], bookings: [Booking] = [], since: Date = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: .now)) ?? .distantPast) -> Double {
        let subTotal = subs.filter(\.isActive).reduce(0) { $0 + $1.tier.referenceAmount }
        let tipTotal = tips.filter { $0.createdAt >= since }.reduce(0) { $0 + $1.amount.referenceAmount }
        let appStorePart = (subTotal + tipTotal) * (1 - appStoreShare) * creatorShare
        let salePart = sales.filter { $0.createdAt >= since }.reduce(0.0) { $0 + creatorTake($1.amountMinor, rail: $1.rail) }
        let bookingPart = bookings.filter { $0.createdAt >= since && ($0.status == .accepted || $0.status == .done) }.reduce(0.0) { $0 + creatorTake($1.amountMinor, rail: $1.rail) }
        return appStorePart + salePart + bookingPart
    }
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
