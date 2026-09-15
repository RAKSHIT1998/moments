import SwiftUI
import UserNotifications

/// "What's worth remembering?" — a feed that MOMENT composes for today. Never a database.
/// Hero moments dominate; every card has one obvious action; nothing is manufactured.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var path = NavigationPath()
    @State private var notificationStatus: UNAuthorizationStatus = .authorized

    private var showNotificationNudge: Bool { notificationStatus == .notDetermined && !env.settings.notificationNudgeDismissed }
    private var heroes: [SurfaceService.FeedItem] { env.surface.feed.filter { $0.recommendation.isHero } }
    private var rest: [SurfaceService.FeedItem] { env.surface.feed.filter { !$0.recommendation.isHero } }

    var body: some View {
        @Bindable var env = env
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: MSpacing.l) {
                    header
                    if env.storageUnavailable { storageBanner }
                    if env.surface.inboxCount > 0 { reviewStrip }
                    sharedWithYou
                    if env.flags.isOn(.monthRecap), let recap = env.stories.pendingMonthRecap() { RecapCard(label: recap.label, count: recap.count) }
                    if env.surface.feed.isEmpty {
                        emptyState
                    } else {
                        ForEach(heroes) { item in HeroCard(item: item) { open(item) } }
                        if env.settings.dailyBriefEnabled, !env.surface.dailyBrief.isEmpty { DailyBriefCard(lines: env.surface.dailyBrief) }
                        ForEach(rest) { item in SurfaceCard(item: item) { open(item) } }
                        if showNotificationNudge { NotificationNudgeCard(status: $notificationStatus) }
                    }
                    #if DEBUG
                    if !env.settings.demoLoaded, env.storage.memoryCount == 0 { demoButton }
                    #endif
                    footer
                }
                .padding(.horizontal, MSpacing.l)
                .padding(.vertical, MSpacing.m)
            }
            .background(AmbientBackdrop(intensity: 0.9).ignoresSafeArea())
            .navigationTitle("MOMENT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { NavigationLink(value: Route.settings) { Image(systemName: "gearshape") }.accessibilityLabel("Settings").accessibilityIdentifier("settingsButton") }
            }
            .momentDestinations()
            .withCaptureButton()
            .refreshable { await env.surface.refresh() }
            .task { notificationStatus = await env.notifications.authorizationStatus() }
            .onChange(of: env.pendingMemoryID) { _, id in
                if let id { path.append(Route.memory(id)); env.pendingMemoryID = nil }
            }
        }
    }

    private func open(_ item: SurfaceService.FeedItem) {
        env.surface.recordUsefulResurface(item.memory, category: item.recommendation.category)
        if item.recommendation.actionKind == .continuePlan, let plan = item.memory.plans.first { path.append(Route.plan(plan.id)) }
        else { path.append(Route.memory(item.memory.id)) }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            Text(greeting).eyebrowStyle()
            Text("What's worth remembering?").displayStyle().accessibilityAddTraits(.isHeader).accessibilityIdentifier("homeHeadline")
        }
        .padding(.top, MSpacing.m)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 5 ? "Late night" : hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        return "\(part) · \(Date.now.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))"
    }

    private var reviewStrip: some View {
        NavigationLink(value: Route.review) {
            HStack(spacing: MSpacing.m) {
                Image(systemName: "tray.full").font(.body.weight(.semibold)).foregroundStyle(MColor.accent)
                    .frame(width: 34, height: 34).background(MColor.accentSoft, in: RoundedRectangle(cornerRadius: MRadius.icon, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(env.surface.inboxCount == 1 ? "1 new Moment to review" : "\(env.surface.inboxCount) new Moments to review").font(MFont.headline)
                    Text("Already understood. Save the ones that matter.").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(MColor.textTertiary)
            }
            .momentCard(padding: MSpacing.m)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityIdentifier("reviewStrip")
    }

    @ViewBuilder
    private var sharedWithYou: some View {
        let received = env.stories.received().filter { $0.updatedAt.daysUntil(.now) <= 14 }
        if !received.isEmpty {
            VStack(alignment: .leading, spacing: MSpacing.s) {
                Text("Shared with you").eyebrowStyle()
                ForEach(received.prefix(3)) { s in
                    Button { env.stories.pendingStoryID = s.id } label: { StoryRow(story: s) }.buttonStyle(PressScaleStyle())
                }
            }
        }
    }

    private var storageBanner: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            Label("Your memory store couldn't be opened", systemImage: "exclamationmark.triangle").font(MFont.headline).foregroundStyle(MColor.warning)
            Text("MOMENT is running without saving. Restart the app; if this keeps happening, please contact support.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
        }.momentCard()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            Text(env.storage.memoryCount == 0 ? "Nothing here yet." : "Nothing needs you yet.").font(MFont.title).tracking(-0.3)
            Text(env.storage.memoryCount == 0 ? "Throw something at me — a screenshot, a voice note, a thought. I'll bring it back when it matters." : "That's a good thing. When a promise goes stale, a birthday gets close, or a plan's time is near, it shows up here.")
                .font(MFont.body).foregroundStyle(MColor.textSecondary)
            if !env.settings.hasSeenTryIt, env.storage.memoryCount == 0 { TryItCard() }
            else if env.storage.memoryCount == 0 { Button("Capture a Moment") { env.showCapture = true }.buttonStyle(ChipButtonStyle(prominent: true)) }
        }
        .momentCard()
    }

    #if DEBUG
    private var demoButton: some View {
        Button { Task { await DemoData.seedAsync(into: env) } } label: { Label("Load demo data (DEBUG)", systemImage: "flask") }
            .font(MFont.subheadline)
            .accessibilityIdentifier("loadDemo")
    }
    #endif

    private var footer: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            let resurfaced = env.surface.resurfacedThisMonth()
            if resurfaced > 0 {
                Text("\(resurfaced) Moment\(resurfaced == 1 ? "" : "s") remembered for you this month.")
                    .font(MFont.footnote).foregroundStyle(MColor.textTertiary)
                    .padding(.top, MSpacing.s)
            }
        }
    }
}

// MARK: - Hero

/// The dominant card. One or two per day, only when something genuinely important is near.
struct HeroCard: View {
    @Environment(AppEnvironment.self) private var env
    let item: SurfaceService.FeedItem
    let open: () -> Void
    @State private var showReminder = false
    private var rec: SurfaceEngine.Recommendation { item.recommendation }

    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            HStack(spacing: 6) {
                Image(systemName: HomeView.symbol(for: rec.category)).font(.caption.weight(.semibold))
                Text(rec.category.rawValue).eyebrowStyle().foregroundStyle(.white.opacity(0.85))
                Spacer()
                CardMenu(item: item, showReminder: $showReminder)
            }
            .foregroundStyle(.white.opacity(0.9))
            Text(rec.headline).font(.system(.title, weight: .bold)).tracking(-0.5).foregroundStyle(.white)
            if let d = rec.detail { Text(d).font(MFont.body).foregroundStyle(.white.opacity(0.85)) }
            HStack(spacing: MSpacing.s) {
                PrimaryAction(item: item, open: open, light: true)
                if rec.actionKind == .followUp || rec.actionKind == .viewGift { Button("Remind me") { showReminder = true }.buttonStyle(ChipButtonStyle(light: true)) }
                Spacer()
            }
            .padding(.top, MSpacing.xs)
        }
        .padding(MSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MColor.accentGradient, in: RoundedRectangle(cornerRadius: MRadius.card, style: .continuous))
        .shadow(color: MShadow.accent.color, radius: MShadow.accent.radius, y: MShadow.accent.y)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("surfaceCard-\(rec.category.rawValue)")
        .accessibilityLabel("\(rec.category.rawValue): \(rec.headline). \(rec.detail ?? "")")
        .accessibilityAction(named: "Open", open)
        .sheet(isPresented: $showReminder) { ReminderSheet(memory: item.memory) }
    }
}

// MARK: - Card

/// Editorial card: eyebrow, headline, one primary action. No competing buttons.
struct SurfaceCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: SurfaceService.FeedItem
    let open: () -> Void
    @State private var showReminder = false
    private var rec: SurfaceEngine.Recommendation { item.recommendation }

    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            HStack(spacing: 6) {
                Image(systemName: HomeView.symbol(for: rec.category)).font(.caption.weight(.semibold)).foregroundStyle(MColor.accent).accessibilityHidden(true)
                Text(rec.category.rawValue).eyebrowStyle().accessibilityIdentifier("surfaceEyebrow")
                Spacer()
                if let d = rec.detail, rec.category == .followUp { Text(d).font(MFont.caption).foregroundStyle(MColor.textTertiary) }
                CardMenu(item: item, showReminder: $showReminder)
            }
            Text(rec.headline).font(MFont.title).tracking(-0.3)
            if let d = rec.detail, rec.category != .followUp { Text(d).font(MFont.body).foregroundStyle(MColor.textSecondary) }
            HStack(spacing: MSpacing.s) {
                PrimaryAction(item: item, open: open, light: false)
                if rec.actionKind == .followUp { Button("Remind me") { showReminder = true }.buttonStyle(ChipButtonStyle()) }
                Spacer()
            }
        }
        .momentCard()
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("surfaceCard-\(rec.category.rawValue)")
        .accessibilityLabel("\(rec.category.rawValue): \(rec.headline). \(rec.detail ?? "")")
        .accessibilityAction(named: "Open", open)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
        .sheet(isPresented: $showReminder) { ReminderSheet(memory: item.memory) }
    }
}

/// The one obvious action per card.
private struct PrimaryAction: View {
    @Environment(AppEnvironment.self) private var env
    let item: SurfaceService.FeedItem
    let open: () -> Void
    let light: Bool
    private var rec: SurfaceEngine.Recommendation { item.recommendation }

    var body: some View {
        switch rec.actionKind {
        case .followUp: Button("Done") { done() }.buttonStyle(ChipButtonStyle(prominent: true, light: light))
        case .completeTask: Button("Done") { env.actions.completeTask(item.memory); finish() }.buttonStyle(ChipButtonStyle(prominent: true, light: light))
        case .viewGift: Button("View gift idea", action: open).buttonStyle(ChipButtonStyle(prominent: true, light: light))
        case .continuePlan: Button("Continue", action: open).buttonStyle(ChipButtonStyle(prominent: true, light: light))
        case .markDone, .open: Button(rec.category == .remembered ? "Open memory" : "Open", action: open).buttonStyle(ChipButtonStyle(prominent: true, light: light))
        }
    }

    private func done() {
        if let p = item.memory.promises.first(where: { $0.status == .pending }) { env.actions.complete(p) } else { env.actions.completeTask(item.memory) }
        finish()
    }
    private func finish() {
        env.surface.recordUsefulResurface(item.memory, category: rec.category)
        Haptics.completed()
        env.toast("Done.")
        Task { await env.surface.refresh(scheduleNotifications: false) }
    }
}

/// Feedback: useful / not useful / don't remind / why am I seeing this.
private struct CardMenu: View {
    @Environment(AppEnvironment.self) private var env
    let item: SurfaceService.FeedItem
    @Binding var showReminder: Bool
    @State private var showWhy = false
    var body: some View {
        Menu {
            Button { showWhy = true } label: { Label("Why am I seeing this?", systemImage: "questionmark.circle") }
            Button { env.surface.recordUsefulResurface(item.memory, category: item.recommendation.category); env.toast("Thanks — I'll show more like this.") } label: { Label("This was useful", systemImage: "hand.thumbsup") }
            Button { env.surface.recordNotUseful(item.memory, category: item.recommendation.category); env.toast("Got it — fewer like this.") } label: { Label("Not useful", systemImage: "hand.thumbsdown") }
            Button { showReminder = true } label: { Label("Remind me later", systemImage: "bell") }
            Button(role: .destructive) { env.surface.mute(item.memory); env.toast("I won't bring this up again.") } label: { Label("Don't remind me about this", systemImage: "bell.slash") }
        } label: {
            Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .accessibilityLabel("More options")
        .sheet(isPresented: $showWhy) {
            WhySheet(title: item.recommendation.headline, explanation: item.recommendation.reason, source: item.memory.source.map { ($0.type, item.memory.createdAt) })
        }
    }
}

extension HomeView {
    static func symbol(for c: SurfaceEngine.Category) -> String {
        switch c {
        case .followUp: "hand.raised"
        case .upcoming: "calendar"
        case .remembered: "clock.arrow.circlepath"
        case .opportunity: "gift"
        case .plan: "map"
        case .people: "person"
        case .today: "sun.max"
        }
    }
}

// MARK: - Reminder: "When should I bring this back?"

struct ReminderSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let memory: Memory
    @State private var showPicker = false
    @State private var date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date.now.adding(days: 1)) ?? .now

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                Text("When should I bring this back?").font(MFont.title).tracking(-0.3)
                Text(memory.title).font(MFont.subheadline).foregroundStyle(MColor.textSecondary).lineLimit(2)
                VStack(spacing: MSpacing.s) {
                    option("Tonight", "moon", tonight)
                    option("Tomorrow morning", "sunrise", at(9, daysAhead: 1))
                    option("This weekend", "beach.umbrella", weekend)
                    option("Next week", "calendar", at(9, daysAhead: 7))
                    if let e = memory.events.first ?? memory.giftIdeas.first?.person?.birthday.map({ Event(title: "birthday", date: $0, isAnnual: true) }) {
                        let d = Calendar.current.date(byAdding: .day, value: -3, to: e.nextOccurrence())
                        if let d, d > .now { option("3 days before \(e.title.lowercased().contains("birthday") ? "the birthday" : "the event")", "gift", d) }
                    }
                    Button { showPicker.toggle() } label: { row("Pick a date", "calendar.badge.clock", trailing: showPicker ? "chevron.up" : "chevron.down") }.buttonStyle(.plain)
                    if showPicker {
                        DatePicker("Date", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute]).datePickerStyle(.graphical)
                        Button("Set reminder") { set(date) }.buttonStyle(PrimaryButtonStyle())
                    }
                }
                Spacer()
            }
            .padding(MSpacing.l)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func option(_ label: String, _ symbol: String, _ d: Date?) -> some View {
        Button { if let d { set(d) } } label: { row(label, symbol, trailing: nil, subtitle: d?.formatted(date: .abbreviated, time: .shortened)) }
            .buttonStyle(.plain).disabled(d == nil)
    }
    private func row(_ label: String, _ symbol: String, trailing: String?, subtitle: String? = nil) -> some View {
        HStack(spacing: MSpacing.m) {
            Image(systemName: symbol).foregroundStyle(MColor.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(MFont.body).foregroundStyle(MColor.textPrimary)
                if let subtitle { Text(subtitle).font(MFont.caption).foregroundStyle(MColor.textTertiary) }
            }
            Spacer()
            if let trailing { Image(systemName: trailing).font(.caption).foregroundStyle(MColor.textTertiary) }
        }
        .padding(MSpacing.m)
        .frame(minHeight: MTouch.minimum)
        .background(MColor.surface, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
        .contentShape(Rectangle())
    }

    private var tonight: Date? {
        let d = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: .now)
        return (d ?? .now) > .now ? d : nil
    }
    private var weekend: Date? {
        var c = DateComponents(); c.weekday = 7; c.hour = 10
        return Calendar.current.nextDate(after: .now, matching: c, matchingPolicy: .nextTime)
    }
    private func at(_ hour: Int, daysAhead: Int) -> Date? { Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date.now.adding(days: daysAhead)) }

    private func set(_ d: Date) {
        env.actions.setReminder(memory, at: d)
        env.surface.recordUsefulResurface(memory)
        Task {
            if await env.notifications.authorizationStatus() == .notDetermined { _ = await env.notifications.requestAuthorization() }
            await env.surface.refresh()
        }
        Haptics.saved()
        env.toast("I'll bring it back \(d.relativeDescription.lowercased()).")
        dismiss()
    }
}

// MARK: - Brief, nudge, try-it

/// "Your September in Moments" — offered once, after the month has ended, only if there's substance.
struct RecapCard: View {
    @Environment(AppEnvironment.self) private var env
    let label: String
    let count: Int
    @State private var openEditor: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            Text("Your month in Moments").eyebrowStyle()
            Text("\(label): \(count) memories worth remembering.").font(MFont.title).tracking(-0.3)
            Text("People, places, the plans you made and the ones that happened. Yours to keep or share.").font(MFont.body).foregroundStyle(MColor.textSecondary)
            HStack(spacing: MSpacing.s) {
                Button("See it") {
                    if let d = Calendar.current.date(byAdding: .month, value: -1, to: .now), let s = env.stories.monthRecap(for: d) { env.stories.markMonthRecapShown(); openEditor = s.id }
                }.buttonStyle(ChipButtonStyle(prominent: true))
                Button("Not now") { env.stories.markMonthRecapShown() }.buttonStyle(ChipButtonStyle())
            }
        }
        .momentCard()
        .navigationDestination(item: $openEditor) { id in MomentEditorView(storyID: id) }
    }
}

struct DailyBriefCard: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            Text("Your Moment").eyebrowStyle()
            ForEach(lines, id: \.self) { Text($0).font(MFont.body) }
        }
        .momentCard()
        .accessibilityElement(children: .combine)
    }
}

/// Asked once, in context: only after MOMENT has something worth resurfacing.
struct NotificationNudgeCard: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var status: UNAuthorizationStatus
    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            Text("At the right time").eyebrowStyle()
            Text("Want me to tell you when one of these becomes urgent? At most \(env.settings.dailyNotificationBudget) a day, never “come back to the app”. Details stay hidden unless you turn them on.").font(MFont.body)
            HStack(spacing: MSpacing.s) {
                Button("Notify me") { Task { _ = await env.notifications.requestAuthorization(); status = await env.notifications.authorizationStatus(); await env.surface.refresh() } }.buttonStyle(ChipButtonStyle(prominent: true))
                Button("Not now") { env.settings.notificationNudgeDismissed = true }.buttonStyle(ChipButtonStyle())
            }
        }
        .momentCard()
    }
}

/// First-run demonstration: clearly an example, run through the real engine, then "now give me something real".
struct TryItCard: View {
    @Environment(AppEnvironment.self) private var env
    @State private var demoResult: AnalysisResult?

    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            Text("Try this").eyebrowStyle()
            Text("Imagine Sarah texts you:").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
            Text("“I really want these New Balance 530 😍”").font(MFont.headline)
            if let r = demoResult, let m = r.memories.first {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(m.memoryType.label).eyebrowStyle(); Spacer(); Text("Example").font(MFont.caption).foregroundStyle(MColor.textTertiary) }
                    Text(m.title).font(MFont.title).tracking(-0.3)
                    Text(m.summary).font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                }
                .padding(MSpacing.m)
                .background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.chip))
                Text("Now give me something from your life.").font(MFont.body)
                Button("Capture a Moment") { env.settings.hasSeenTryIt = true; env.showCapture = true }.buttonStyle(ChipButtonStyle(prominent: true))
            } else {
                Button("See what MOMENT understands") {
                    Task {
                        let input = CaptureInput(payload: .text("Sarah\n\nSarah: I really want these New Balance 530 😍\nYou: noted\n10:32 PM"), sourceType: .screenshot)
                        demoResult = try? await LocalIntelligenceProvider().analyze(input, context: .empty)
                    }
                }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .accessibilityIdentifier("tryItButton")
            }
        }
    }
}
