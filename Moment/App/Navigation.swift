import SwiftUI

/// Every push destination in the app. Views navigate with values, not view instances.
enum Route: Hashable {
    case memory(UUID)
    case person(UUID)
    case plan(UUID)
    case plans, promises, gifts, timeline, insights, settings, privacy, aiSettings, notificationSettings, dataSettings, subscription, about
    case review, pinned, stats, homeSettings
    case moments, momentEditor(UUID), friendship(UUID)
}

extension View {
    /// Registers all destinations once per NavigationStack.
    func momentDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .memory(let id): MemoryDetailView(memoryID: id)
            case .person(let id): PersonProfileView(personID: id)
            case .plan(let id): PlanDetailView(planID: id)
            case .plans: PlansListView()
            case .promises: PromisesListView()
            case .gifts: GiftIdeasListView()
            case .timeline: VaultView(embedded: true)
            case .insights: InsightsView()
            case .settings: SettingsView()
            case .privacy: PrivacyCenterView()
            case .aiSettings: AISettingsView()
            case .notificationSettings: NotificationSettingsView()
            case .dataSettings: DataSettingsView()
            case .subscription: PaywallView(presentedAsSheet: false)
            case .about: AboutView()
            case .review: ReviewView()
            case .pinned: PinnedView()
            case .stats: MemoryStatsView()
            case .homeSettings: HomeSettingsView()
            case .moments: MomentsHubView()
            case .momentEditor(let id): MomentEditorView(storyID: id)
            case .friendship(let id): FriendshipView(personID: id)
            }
        }
        .navigationDestination(for: SocialRoute.self) { route in
            switch route {
            case .moment(let id): MomentPageView(momentID: id)
            case .newMoment: NewMomentView()
            case .addSide(let id): AddSideView(momentID: id)
            case .profile(let id): SocialProfileView(userID: id)
            case .friendship(let id): FriendshipPageView(userID: id)
            case .conversation(let id): ConversationView(conversationID: id)
            case .editMoment(let id): EditMomentView(momentID: id)
            case .members(let id): MembersView(momentID: id)
            case .safety: SafetySettingsView()
            case .blockedUsers: BlockedUsersView()
            case .followers(let id, let followers): FollowListView(userID: id, followers: followers)
            case .editProfile: EditProfileView()
            case .myMemories: PrivateMemoryHubView()
            case .collections: CollectionsView()
            case .collection(let id): CollectionDetailView(collectionID: id)
            }
        }
    }
}

/// The floating "+ MOMENT" capture button, present on every tab.
struct CaptureFAB: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false
    var body: some View {
        Button {
            env.showCapture = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.headline.weight(.bold))
                Text("MOMENT").font(.headline.weight(.bold)).tracking(1.2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
            .background(MColor.accentGradient, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: MColor.accent.opacity(0.40), radius: 16, y: 8)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Capture a Moment")
        .accessibilityIdentifier("captureButton")
        .padding(.bottom, MSpacing.s)
    }
}

/// Gentle press feedback used on primary tappables.
struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.25), value: configuration.isPressed)
    }
}

extension View {
    func withCaptureButton() -> some View {
        safeAreaInset(edge: .bottom) {
            HStack { Spacer(); CaptureFAB(); Spacer() }
        }
    }
}
