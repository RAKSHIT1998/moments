import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var tab: RootTab = .home

    var body: some View {
        @Bindable var env = env
        Group {
            if !env.settings.onboardingCompleted {
                SocialOnboardingView()
            } else if !env.settings.setupCompleted {
                SetupView()
            } else {
                mainTabs
            }
        }
        .modifier(ToastHost())
        .overlay {
            if env.lock.isLocked { LockScreenView() }
        }
        .sheet(isPresented: $env.showCapture) {
            CaptureSheet(initialInput: env.pendingCaptureInput)
                .onDisappear { env.pendingCaptureInput = nil }
        }
        .onChange(of: env.pendingTab) { _, newTab in
            if let newTab { tab = newTab; env.pendingTab = nil }
        }
        .fullScreenCover(item: pendingStory) { id in
            NavigationStack { MomentViewerView(storyID: id).momentDestinations() }
        }
        .fullScreenCover(item: pendingMoment) { boxed in
            PendingMomentCover(momentID: boxed.id)
        }
        .sheet(isPresented: sharedForMoment) { AddSharedToMomentSheet() }
        .alert("Couldn't open that Moment", isPresented: importErrorShown) { Button("OK") {} } message: { Text(env.stories.lastImportError ?? "") }
        .alert("Couldn't join that Moment", isPresented: inviteErrorShown) { Button("OK") {} } message: { Text(env.social.pendingInviteError ?? "") }
    }

    private var pendingStory: Binding<UUID?> { Binding(get: { env.stories.pendingStoryID }, set: { env.stories.pendingStoryID = $0 }) }
    private var pendingMoment: Binding<BoxedID?> { Binding(get: { env.social.pendingMomentID.map(BoxedID.init) }, set: { env.social.pendingMomentID = $0?.id }) }
    private var sharedForMoment: Binding<Bool> { Binding(get: { !env.shareInbox.pendingForMoment.isEmpty && env.settings.onboardingCompleted }, set: { if !$0 { env.shareInbox.clearPendingForMoment() } }) }
    private var importErrorShown: Binding<Bool> { Binding(get: { env.stories.lastImportError != nil }, set: { _ in env.stories.lastImportError = nil }) }
    private var inviteErrorShown: Binding<Bool> { Binding(get: { env.social.pendingInviteError != nil }, set: { _ in env.social.pendingInviteError = nil }) }

    private var mainTabs: some View {
        TabView(selection: $tab) {
            Tab(RootTab.home.label, systemImage: RootTab.home.symbol, value: .home) { SocialHomeView() }
            Tab(RootTab.discover.label, systemImage: RootTab.discover.symbol, value: .discover) { DiscoverView() }
            Tab(RootTab.create.label, systemImage: RootTab.create.symbol, value: .create) { CreateTab(tab: $tab) }
            Tab(RootTab.inbox.label, systemImage: RootTab.inbox.symbol, value: .inbox) { InboxView() }
                .badge(env.social.unreadActivity)
            Tab(RootTab.profile.label, systemImage: RootTab.profile.symbol, value: .profile) {
                NavigationStack { SocialProfileView(userID: env.social.myID).socialDestinations() }
            }
        }
        .tint(MColor.accent)
    }
}

struct BoxedID: Identifiable, Hashable { let id: String }

/// A Moment opened from a link, notification or invite.
struct PendingMomentCover: View {
    @Environment(AppEnvironment.self) private var env
    let momentID: String
    var body: some View {
        NavigationStack {
            MomentPageView(momentID: momentID)
                .socialDestinations()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { env.social.pendingMomentID = nil }.accessibilityIdentifier("closeMoment") } }
        }
    }
}

struct CreateTab: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var tab: RootTab
    @State private var generation = 0
    var body: some View {
        NavigationStack {
            NewMomentView(initial: env.social.remixDraft) { m in
                env.social.remixDraft = nil
                generation += 1
                tab = .home
                env.social.pendingMomentID = m.id
            }
            .socialDestinations()
        }
        .id("\(generation)-\(env.social.remixDraft?.remixedFromID ?? "new")")
    }
}

/// Shown over everything while Face ID is required.
struct LockScreenView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        ZStack {
            AmbientBackdrop().ignoresSafeArea()
            VStack(spacing: MSpacing.xl) {
                Image(systemName: "lock.fill").font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: MIcon.hero, height: MIcon.hero).background(MColor.accentGradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .accessibilityHidden(true)
                VStack(spacing: MSpacing.xs) {
                    Text("MOMENT is locked").font(MFont.title)
                    Text("Your memories stay private.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                }
                Button("Unlock with \(env.lock.biometrics.label)") { Task { await env.lock.unlock() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 280)
            }
        }
        .accessibilityAddTraits(.isModal)
        .task { await env.lock.unlock() }
    }
}
