import Foundation

/// Anonymous product events, opt-in, and never any memory content. In V1 there is no backend:
/// events are counted locally so the north-star metric can be shown in Settings › About.
@MainActor
final class AnalyticsService {
    enum Event: String {
        case captureStarted = "capture_started"
        case captureCompleted = "capture_completed"
        case memoryCreated = "memory_created"
        case memoryEdited = "memory_edited"
        case memoryDeleted = "memory_deleted"
        case searchUsed = "search_used"
        case insightOpened = "insight_opened"
        case notificationOpened = "notification_opened"
        case subscriptionStarted = "subscription_started"
        case subscriptionCancelled = "subscription_cancelled"
        case usefulMemoryResurfaced = "useful_memory_resurfaced"
        // Growth loop (names only, never content)
        case firstMomentCreated = "first_moment_created"
        case momentCreated = "moment_created"
        case momentShared = "moment_shared"
        case momentExportedVideo = "moment_exported_video"
        case sharedMomentOpened = "shared_moment_opened"
        case sideAdded = "side_added"
        case reactionAdded = "reaction_added"
        case momentRemixed = "moment_remixed"
        case recapViewed = "recap_viewed"
        case memoryDropCreated = "memory_drop_created"
        case contextualInviteShown = "contextual_invite_shown"
        case contextualInviteAccepted = "contextual_invite_accepted"
        // Social platform (north star: shared Moments — Moments with more than one member)
        case sharedMomentCreated = "shared_moment_created"
        case inviteSent = "invite_sent"
        case momentJoined = "moment_joined"
        case nowPosted = "now_posted"
        case nowSaved = "now_saved"
        case commentAdded = "comment_added"
        case messageSent = "message_sent"
        case userBlocked = "user_blocked"
        case reportSent = "report_sent"
        case activityStarted = "activity_started"
        case qrScanned = "qr_scanned"
        case placeClaimed = "place_claimed"
        case creatorPlanCreated = "creator_plan_created"
        case creatorSubscribed = "creator_subscribed"
        case creatorTipped = "creator_tipped"
    }

    /// Number of Moments this person made that became shared (someone else was invited).
    var sharedMomentsCreated: Int { count(.sharedMomentCreated) }

    /// "Moments shared per activated user" — the primary growth metric, computed locally.
    var momentsSharedPerActivatedUser: Double {
        let activated = count(.firstMomentCreated) > 0 ? 1.0 : 0.0
        return activated == 0 ? 0 : Double(count(.momentShared))
    }

    private let settings: SettingsStore
    private let defaults = UserDefaults.standard

    init(settings: SettingsStore) { self.settings = settings }

    /// Only the event name and an optional *category* string are recorded. Never text, names, URLs.
    func track(_ event: Event, category: String? = nil) {
        let growth: Set<Event> = [.usefulMemoryResurfaced, .firstMomentCreated, .momentCreated, .momentShared, .sharedMomentOpened, .sideAdded, .momentRemixed, .sharedMomentCreated, .inviteSent, .momentJoined]
        guard settings.analyticsEnabled || growth.contains(event) else { return }
        let key = "analytics.\(event.rawValue)"
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
        Log.app.debug("event \(event.rawValue, privacy: .public) \(category ?? "", privacy: .public)")
    }

    func count(_ event: Event) -> Int { defaults.integer(forKey: "analytics.\(event.rawValue)") }

    func reset() {
        for e in [Event.captureStarted, .captureCompleted, .memoryCreated, .memoryEdited, .memoryDeleted, .searchUsed, .insightOpened, .notificationOpened, .subscriptionStarted, .subscriptionCancelled, .usefulMemoryResurfaced, .firstMomentCreated, .momentCreated, .momentShared, .momentExportedVideo, .sharedMomentOpened, .sideAdded, .reactionAdded, .momentRemixed, .recapViewed, .memoryDropCreated, .contextualInviteShown, .contextualInviteAccepted, .sharedMomentCreated, .inviteSent, .momentJoined, .nowPosted, .nowSaved, .commentAdded, .messageSent, .userBlocked, .reportSent, .activityStarted, .qrScanned, .placeClaimed] {
            defaults.removeObject(forKey: "analytics.\(e.rawValue)")
        }
    }
}
