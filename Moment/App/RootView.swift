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

    @State private var showCreate = false
    @State private var lastTab: RootTab = .home

    private var mainTabs: some View {
        TabView(selection: $tab) {
            Tab(RootTab.home.label, systemImage: RootTab.home.symbol, value: .home) { SocialHomeView() }
            Tab(RootTab.discover.label, systemImage: RootTab.discover.symbol, value: .discover) { DiscoverView() }
            Tab(RootTab.create.label, systemImage: RootTab.create.symbol, value: .create) { Color.clear }
            Tab(RootTab.now.label, systemImage: RootTab.now.symbol, value: .now) { NowView() }
            Tab(RootTab.profile.label, systemImage: RootTab.profile.symbol, value: .profile) {
                NavigationStack { SocialProfileView(userID: env.social.myID).socialDestinations() }
            }
        }
        .tint(MColor.textPrimary)
        .onChange(of: tab) { old, new in
            // The centre "+" is an action, not a place: open the create sheet and stay where you were.
            if new == .create { showCreate = true; tab = old == .create ? .home : old } else { lastTab = new }
        }
        .sheet(isPresented: $showCreate) { CreateSheet() }
    }
}

/// CREATE → Moment / NOW / Event. A small sheet, three choices, no menu wall.
struct CreateSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var next: Kind?
    enum Kind: String, Identifiable { case moment, now, event; var id: String { rawValue } }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                Text("Create").displayStyle().padding(.top, MSpacing.s)
                row(.moment, "Moment", "From photos. Invite the people who were there.", "rectangle.stack")
                row(.now, "NOW", "What you're up to, right now. Gone in hours.", "sparkle")
                row(.event, "Event", "A QR on the table. People scan, they're in.", "qrcode")
                Spacer()
            }
            .padding(.horizontal, MSpacing.page)
            .background(MColor.background)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationDestination(item: $next) { kind in
                switch kind {
                case .moment: NewMomentView(initial: env.social.remixDraft) { m in env.social.remixDraft = nil; dismiss(); env.social.pendingMomentID = m.id }.socialDestinations()
                case .now: AnyoneUpComposerBody()
                case .event: StartActivityBody()
                }
            }
        }
        .presentationDetents(next == nil ? [.medium] : [.large], selection: .constant(next == nil ? .medium : .large))
        .presentationDragIndicator(.visible)
    }

    private func row(_ kind: Kind, _ title: String, _ detail: String, _ symbol: String) -> some View {
        Button { next = kind } label: {
            HStack(spacing: MSpacing.l) {
                Image(systemName: symbol).font(.title3.weight(.light)).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(MFont.headline).foregroundStyle(MColor.textPrimary)
                    Text(detail).font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(MColor.textTertiary)
            }
            .padding(.vertical, MSpacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Rectangle().fill(MColor.separator).frame(height: 0.5), alignment: .bottom)
        .accessibilityIdentifier("create-\(kind.rawValue)")
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
