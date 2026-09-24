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

    /// The system tab bar is a slab welded to the bottom edge. `FloatingTabBar` is a glass pill that
    /// content scrolls under, so a feed reads as one column instead of stopping at a hard line — and the
    /// bar sits inside the safe area rather than on top of the last row of every list.
    ///
    /// The TabView underneath is kept (with its own bar hidden) because it is what preserves each tab's
    /// navigation stack. Swapping it for a switch would throw that away and make Back behave differently
    /// depending on which tab you were in.
    private var mainTabs: some View {
        TabView(selection: $tab) {
            Tab(value: .home) { SocialHomeView().toolbar(.hidden, for: .tabBar) } label: { Text(RootTab.home.label) }
            Tab(value: .create) { Color.clear.toolbar(.hidden, for: .tabBar) } label: { Text(RootTab.create.label) }
            Tab(value: .chats) { ChatsView().toolbar(.hidden, for: .tabBar) } label: { Text(RootTab.chats.label) }
            Tab(value: .profile) {
                NavigationStack { SocialProfileView(userID: env.social.myID).socialDestinations() }
                    .toolbar(.hidden, for: .tabBar)
            } label: { Text(RootTab.profile.label) }
        }
        .tint(MColor.textPrimary)
        .overlay(alignment: .bottom) {
            FloatingTabBar(selection: $tab, unreadChats: env.social.unreadChats) { showCreate = true }
                .padding(.bottom, 6)
        }
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
