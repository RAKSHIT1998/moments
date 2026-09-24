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
        .alert("Couldn't open that Moment", isPresented: importErrorShown) { Button("OK") {} } message: { Text(env.stories.lastImportError ?? "") }
        .alert("Couldn't join that Moment", isPresented: inviteErrorShown) { Button("OK") {} } message: { Text(env.social.pendingInviteError ?? "") }
    }

    private var pendingStory: Binding<UUID?> { Binding(get: { env.stories.pendingStoryID }, set: { env.stories.pendingStoryID = $0 }) }
    private var pendingMoment: Binding<BoxedID?> { Binding(get: { env.social.pendingMomentID.map(BoxedID.init) }, set: { env.social.pendingMomentID = $0?.id }) }
    private var sharedForMoment: Binding<Bool> { Binding(get: { !env.shareInbox.pendingForMoment.isEmpty && env.settings.onboardingCompleted }, set: { if !$0 { env.shareInbox.clearPendingForMoment() } }) }
    private var importErrorShown: Binding<Bool> { Binding(get: { env.stories.lastImportError != nil }, set: { _ in env.stories.lastImportError = nil }) }
    private var inviteErrorShown: Binding<Bool> { Binding(get: { env.social.pendingInviteError != nil }, set: { _ in env.social.pendingInviteError = nil }) }

    @State private var showCreate = false
    @State private var lastTab: RootTab = .home

    /// The system tab bar, carrying the same SF Symbols the rest of the app uses.
    ///
    /// A floating glass pill was tried here and reverted. It looked better, but as an overlay it has no
    /// layout presence and landed on top of the chat composer — the message box was invisible and
    /// untappable, confirmed on screen. Reserving space for it four different ways (an inset on the
    /// TabView, a spacer inside each tab, per-screen padding, the bar itself as a per-tab safe-area
    /// inset) moved the composer not one point, because a view pushed inside a tab's NavigationStack
    /// does not pick the inset up. Worth another go with a working machine and a real device; not worth
    /// shipping a bar that hides the thing people type into.
    private var mainTabs: some View {
        TabView(selection: $tab) {
            Tab(value: .home) { SocialHomeView() } label: { Label(RootTab.home.label, systemImage: MSymbol.home.off) }
            Tab(value: .create) { Color.clear } label: { Label(RootTab.create.label, systemImage: MSymbol.create.off) }
            Tab(value: .chats) { ChatsView() } label: { Label(RootTab.chats.label, systemImage: MSymbol.chats.off) }
                .badge(env.social.unreadChats)
            Tab(value: .profile) { NavigationStack { SocialProfileView(userID: env.social.myID).socialDestinations() } } label: { Label(RootTab.profile.label, systemImage: MSymbol.profile.off) }
        }
        .tint(MColor.accent)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onChange(of: tab) { old, new in
            // The centre "+" is an action, not a place: open the create sheet and stay where you were.
            if new == .create { showCreate = true; tab = old == .create ? .home : old } else { lastTab = new }
        }
        .sheet(isPresented: $showCreate) { CreateSheet() }
    }
}

/// CREATE → what a creator actually publishes. Everything here makes money or leads to it.
struct CreateSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var newSet = false
    @State private var newVideo = false
    @State private var showMass = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: MSpacing.m) {
                Text("Create").displayStyle().padding(.top, MSpacing.s)
                row("Photo set", "Free to pull people in, or priced. You set it.", "photo.stack") { newSet = true }
                row("Video post", "A clip for the reels feed. Free or locked.", "play.rectangle.fill") { newVideo = true }
                if env.social.isCreator {
                    row("Message everyone", "One message to every subscriber, in their own chat.", "megaphone.fill") { showMass = true }
                }
                row(env.social.myPlan == nil ? "Your subscription" : "Edit subscription", env.social.myPlan == nil ? "One price, 30 days. Your call." : "Price, bundles, goal and payouts.", "crown.fill") { dismiss(); env.pendingTab = .profile }
                Spacer()
                Text("Everything you post stays on your storage. Buyers get a key, not a copy from us.")
                    .font(MFont.footnote).foregroundStyle(MColor.textTertiary)
            }
            .padding(.horizontal, MSpacing.page)
            .background(MColor.background)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .sheet(isPresented: $newSet, onDismiss: { dismiss() }) { EditSetSheet(set: nil) }
        .sheet(isPresented: $newVideo, onDismiss: { dismiss() }) { EditSetSheet(set: nil) }
        .sheet(isPresented: $showMass, onDismiss: { dismiss() }) { MassMessageSheet() }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func row(_ title: String, _ detail: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: MSpacing.l) {
                Image(systemName: symbol).font(.title3).foregroundStyle(MColor.accent).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(MFont.headline).foregroundStyle(MColor.textPrimary)
                    Text(detail).font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(MColor.textTertiary)
            }
            .padding(.vertical, MSpacing.m)
            .padding(.horizontal, MSpacing.l)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glass(radius: 18)
        .accessibilityIdentifier("create-\(title.lowercased().split(separator: " ").first ?? "row")")
    }
}

struct BoxedID: Identifiable, Hashable { let id: String }


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
