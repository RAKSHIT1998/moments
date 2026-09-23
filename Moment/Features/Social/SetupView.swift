import SwiftUI
import PhotosUI

/// One-time setup after onboarding: the few things that make the app useful on day one.
/// Every step is skippable; the checklist can be reopened from Settings.
struct SetupView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showProfile = false
    @State private var showPeople = false
    @State private var showGroup = false
    @State private var picked: [SocialUser] = []
    @State private var notificationsGranted: Bool? = nil
    @State private var loadingDemo = false

    private var profileDone: Bool { !(env.social.me?.displayName.isEmpty ?? true) && env.social.me?.displayName != "You" || !env.settings.displayName.isBlank }
    private var peopleDone: Bool { !env.social.graph.following.isEmpty }
    private var groupDone: Bool { !env.social.groups.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MSpacing.xl) {
                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        Text("SET UP ONCE").font(MFont.eyebrow).tracking(1.5).foregroundStyle(MColor.accent)
                        Text("Make it yours.").displayStyle()
                        Text("A minute now, then you're in. Skip anything — you can do it later from Settings.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                    }
                    AccountBanner()
                    step(done: profileDone, symbol: "person.crop.circle", title: "Your name & photo", detail: "How you appear on your page and in chats.", action: "Edit") { showProfile = true }
                    step(done: notificationsGranted == true, symbol: "bell.badge", title: "Know when you get paid", detail: "\"Rahul subscribed\" — sales, tips and asks, never the content.", action: notificationsGranted == false ? "Off" : "Allow") {
                        Task { notificationsGranted = await env.notifications.requestAuthorization() }
                    }
                    step(done: peopleDone, symbol: "person.2", title: "Find your people", detail: "Follow the creators you want in your feed.", action: "Search") { showPeople = true }
                    step(done: groupDone, symbol: "person.3", title: "Start a group", detail: "The crew, family, work — one private chat for the people in it.", action: "Create") { showGroup = true }
                    #if DEBUG
                    demoCard
                    #endif
                    Button { finish() } label: { Text(profileDone || peopleDone || groupDone ? "Done" : "Skip for now").frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("setupDone")
                }
                .padding(MSpacing.l).padding(.bottom, MSpacing.xxl)
            }
            .background(AmbientBackdrop().ignoresSafeArea())
            .sheet(isPresented: $showProfile) { NavigationStack { EditProfileView() } }
            .sheet(isPresented: $showGroup) { GroupEditorSheet() }
            .task { await env.social.start(); notificationsGranted = (await env.notifications.authorizationStatus()) == .authorized ? true : nil }
        }
        .modifier(SocialErrorAlert())
    }

    private func step(done: Bool, symbol: String, title: String, detail: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: MSpacing.m) {
            ZStack {
                Circle().fill(done ? MColor.success.opacity(0.15) : MColor.accentSoft).frame(width: 44, height: 44)
                Image(systemName: done ? "checkmark" : symbol).font(.headline).foregroundStyle(done ? MColor.success : MColor.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(MFont.headline)
                Text(detail).font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
            Spacer()
            if !done { Button(action, action: perform).buttonStyle(ChipButtonStyle(prominent: true)).accessibilityIdentifier("setup-\(symbol)") }
        }
        .momentCard(padding: MSpacing.m)
        .accessibilityElement(children: .combine)
    }

    #if DEBUG
    /// Development builds only: run the whole app against sample people and Moments.
    private var demoCard: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            HStack {
                Label("Explore with sample data", systemImage: "sparkles").font(MFont.headline)
                Spacer()
                Text("DEV").font(MFont.eyebrow).foregroundStyle(MColor.warning)
            }
            Text("Fictional friends (Rahul, Sarah, Dev…), a Goa trip, a birthday, a live sunset, NOW posts, a group and private memories — so every screen has something in it. Nothing is uploaded; switch it off in Settings.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            Button {
                loadingDemo = true
                Task { await env.enableDemoMode(); loadingDemo = false; finish() }
            } label: { HStack { if loadingDemo { ProgressView().tint(.white) }; Text(loadingDemo ? "Loading…" : "Load sample data").frame(maxWidth: .infinity) } }
                .buttonStyle(PrimaryButtonStyle(tint: MColor.warning)).disabled(loadingDemo).accessibilityIdentifier("loadDemo")
        }
        .momentCard()
    }
    #endif

    private func finish() {
        env.settings.setupCompleted = true
        Haptics.completed()
    }
}
