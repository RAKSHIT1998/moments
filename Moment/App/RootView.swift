import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var tab: RootTab = .home

    var body: some View {
        @Bindable var env = env
        Group {
            if !env.settings.onboardingCompleted {
                OnboardingView()
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
        .fullScreenCover(item: Binding(get: { env.stories.pendingStoryID }, set: { env.stories.pendingStoryID = $0 })) { id in
            NavigationStack { MomentViewerView(storyID: id).momentDestinations() }
        }
        .alert("Couldn't open that Moment", isPresented: Binding(get: { env.stories.lastImportError != nil }, set: { _ in env.stories.lastImportError = nil })) { Button("OK") {} } message: { Text(env.stories.lastImportError ?? "") }
    }

    private var mainTabs: some View {
        TabView(selection: $tab) {
            Tab(RootTab.home.label, systemImage: RootTab.home.symbol, value: .home) { HomeView() }
            Tab(RootTab.search.label, systemImage: RootTab.search.symbol, value: .search) { SearchView() }
            Tab(RootTab.people.label, systemImage: RootTab.people.symbol, value: .people) { PeopleView() }
            Tab(RootTab.vault.label, systemImage: RootTab.vault.symbol, value: .vault) { VaultView() }
                .badge(env.surface.inboxCount)
        }
        .tint(MColor.accent)
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
