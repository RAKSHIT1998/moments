import SwiftUI

/// Three screens, then your name, then your first Moment. No permission prompts until needed.
struct SocialOnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var name = ""
    @State private var handle = ""
    @State private var saving = false
    @State private var showFirstMoment = false
    @FocusState private var nameFocused: Bool

    private let pages: [(title: String, body: String, symbol: String)] = [
        ("This is where life happens.", "Not what you posted. What happened — with the people who were there.", "camera"),
        ("One Moment.\nEveryone's story.", "You start it. They add their side. One memory, every angle.", "square.stack"),
        ("Let's make your first one.", "A few photos is enough. We'll suggest the rest.", "plus")
    ]

    var body: some View {
        ZStack {
            AmbientBackdrop().ignoresSafeArea()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: MSpacing.xl) {
                            Spacer()
                            Image(systemName: pages[i].symbol).font(.system(size: 30, weight: .semibold)).foregroundStyle(MColor.overlayLight)
                                .frame(width: 68, height: 68).background(MColor.accentGradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                                .shadow(color: MColor.accent.opacity(0.35), radius: 16, y: 8).accessibilityHidden(true)
                            Text(pages[i].title).font(.system(.largeTitle, weight: .bold)).tracking(-0.6).accessibilityAddTraits(.isHeader)
                            Text(pages[i].body).font(.title3).foregroundStyle(MColor.textSecondary).lineSpacing(6)
                            Spacer(); Spacer()
                        }
                        .padding(.horizontal, MSpacing.xxl).frame(maxWidth: .infinity, alignment: .leading).tag(i)
                    }
                    profile.tag(pages.count)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(reduceMotion ? nil : .easeInOut, value: page)

                if page < pages.count {
                    VStack(spacing: MSpacing.m) {
                        HStack(spacing: 6) { ForEach(0...pages.count, id: \.self) { i in Circle().fill(i == page ? MColor.accent : MColor.fill).frame(width: 7, height: 7) } }.accessibilityHidden(true)
                        Button(page == pages.count - 1 ? "Set up your profile" : "Continue") { page += 1 }
                            .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("onboardingContinue")
                    }
                    .padding(.horizontal, MSpacing.xxl).padding(.bottom, MSpacing.xl)
                }
            }
        }
        .fullScreenCover(isPresented: $showFirstMoment) {
            NavigationStack {
                NewMomentView { _ in finish() }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Skip") { finish() }.accessibilityIdentifier("onboardingSkip") } }
            }
        }
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: MSpacing.xl) {
            Spacer()
            Text("What should people call you?").font(MFont.hero).tracking(-0.8)
            VStack(spacing: MSpacing.m) {
                TextField("Your name", text: $name).font(.title2).focused($nameFocused).padding(MSpacing.l)
                    .background(MColor.surface, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
                    .accessibilityIdentifier("onboardingName")
                    .onChange(of: name) { _, n in if handle.isEmpty || handle == Self.suggestHandle(String(n.dropLast())) { handle = Self.suggestHandle(n) } }
                HStack { Text("@").foregroundStyle(MColor.textTertiary); TextField("handle", text: $handle).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("onboardingHandle") }
                    .font(.title3).padding(MSpacing.l).background(MColor.surface, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
            }
            Text(env.social.accountStatus == .available ? "Your profile is stored in your iCloud. Only people you share with see your Moments." : "Sign in to iCloud on this iPhone to share Moments with people. You can still make private ones.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            Spacer()
            Button(saving ? "Saving…" : "Make your first Moment") {
                Task {
                    saving = true
                    env.settings.displayName = name.trimmed
                    if env.social.isSignedIn { _ = await env.social.updateProfile(displayName: name.trimmed, handle: handle, bio: "", avatar: nil) }
                    saving = false
                    showFirstMoment = true
                }
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(name.isBlank || saving).accessibilityIdentifier("onboardingContinue")
            Button("Not now") { env.settings.displayName = name.trimmed; finish() }.font(.subheadline).foregroundStyle(MColor.textSecondary).frame(maxWidth: .infinity).accessibilityIdentifier("onboardingSkip")
        }
        .padding(.horizontal, MSpacing.xxl).padding(.bottom, MSpacing.xl)
        .onAppear { if name.isEmpty { name = env.settings.displayName }; nameFocused = true }
    }

    private func finish() {
        showFirstMoment = false
        env.settings.onboardingCompleted = true
        Task { await env.social.start() }
    }

    static func suggestHandle(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(20))
    }
}
