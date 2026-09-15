import SwiftUI

/// Four screens, zero permission prompts. The fourth screen *is* Capture.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var showDrop = false
    @State private var dropEditor: UUID?

    private let pages: [(title: String, body: String, symbol: String)] = [
        ("Never forget what matters.", "Your private AI memory. It stays on your iPhone.", "lock.shield"),
        ("Throw anything at MOMENT.", "A screenshot.\nA voice note.\nA thought.\nNo folders, no tags.", "square.and.arrow.down.on.square"),
        ("MOMENT connects the dots.", "People.\nPlans.\nPromises.\nMemories — brought back when they matter.", "point.3.connected.trianglepath.dotted")
    ]

    var body: some View {
        ZStack {
            AmbientBackdrop().ignoresSafeArea()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: MSpacing.xl) {
                            Spacer()
                            Image(systemName: pages[i].symbol)
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 68, height: 68)
                                .background(MColor.accentGradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                                .shadow(color: MColor.accent.opacity(0.35), radius: 16, y: 8)
                                .accessibilityHidden(true)
                            Text(pages[i].title).font(.system(.largeTitle, weight: .bold)).tracking(-0.6).accessibilityAddTraits(.isHeader)
                            Text(pages[i].body).font(.title3).foregroundStyle(MColor.textSecondary).lineSpacing(6)
                            Spacer()
                            Spacer()
                        }
                        .padding(.horizontal, MSpacing.xxl)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tag(i)
                    }
                    firstMoment.tag(pages.count)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(reduceMotion ? nil : .easeInOut, value: page)

                if page < pages.count {
                    VStack(spacing: MSpacing.m) {
                        HStack(spacing: 6) {
                            ForEach(0...pages.count, id: \.self) { i in Circle().fill(i == page ? MColor.accent : MColor.fill).frame(width: 7, height: 7) }
                        }.accessibilityHidden(true)
                        Button("Continue") { page += 1 }
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityIdentifier("onboardingContinue")
                    }
                    .padding(.horizontal, MSpacing.xxl)
                    .padding(.bottom, MSpacing.xxl)
                }
            }
        }
    }

    private var firstMoment: some View {
        VStack(alignment: .leading, spacing: MSpacing.xl) {
            Spacer()
            Text("Try it now.").font(.system(.largeTitle, weight: .bold)).tracking(-0.6).accessibilityAddTraits(.isHeader)
            Text(env.flags.isOn(.photoFirstOnboarding) ? "Pick 5–10 photos from a trip or a night out. MOMENT turns them into your first Moment — on your iPhone, in seconds." : "Capture something real — a plan, a promise, something a friend wants. Watch MOMENT understand it.").font(.title3).foregroundStyle(MColor.textSecondary)
            Spacer()
            if env.flags.isOn(.photoFirstOnboarding) {
                Button("Start with photos") { showDrop = true }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("onboardingPhotos")
                Button("Capture something else") { finish(openCapture: true) }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("onboardingCapture")
            } else {
                Button("Capture a Moment") { finish(openCapture: true) }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("onboardingCapture")
            }
            Button("Look around first") { finish(openCapture: false) }
                .font(MFont.subheadline).foregroundStyle(MColor.textSecondary).frame(maxWidth: .infinity, minHeight: MTouch.minimum)
                .accessibilityIdentifier("onboardingSkip")
        }
        .padding(.horizontal, MSpacing.xxl)
        .padding(.bottom, MSpacing.xxl)
        .sheet(isPresented: $showDrop, onDismiss: { if dropEditor != nil { finish(openCapture: false) } }) {
            NavigationStack {
                if let id = dropEditor {
                    MomentEditorView(storyID: id).momentDestinations()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDrop = false } } }
                } else {
                    MemoryDropView { id in dropEditor = id }
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showDrop = false } } }
                }
            }
        }
    }

    private func finish(openCapture: Bool) {
        env.settings.onboardingCompleted = true
        env.storage.profile().onboardingCompletedAt = .now
        env.storage.save()
        if openCapture { env.showCapture = true }
    }
}
