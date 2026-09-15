import SwiftUI

/// The complete archive: review queue, pinned, plans/promises/gifts, tidy-up, stats, and the timeline.
/// Feels like a personal archive, not a table.
struct VaultView: View {
    @Environment(AppEnvironment.self) private var env
    var embedded = false
    @State private var path = NavigationPath()
    @State private var memories: [Memory] = []

    var body: some View {
        if embedded { content } else {
            NavigationStack(path: $path) {
                content
                    .momentDestinations()
                    .withCaptureButton()
            }
        }
    }

    private var content: some View {
        let groups = Dictionary(grouping: memories) { Calendar.current.dateInterval(of: .month, for: $0.createdAt)?.start ?? $0.createdAt }
        let months = groups.keys.sorted(by: >)
        return ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("Vault").eyebrowStyle().padding(.top, MSpacing.m)
                    Text("Your life, remembered.").displayStyle().accessibilityAddTraits(.isHeader)
                }
                if env.surface.inboxCount > 0 {
                    NavigationLink(value: Route.review) { shortcutRow("Review", "\(env.surface.inboxCount) new Moment\(env.surface.inboxCount == 1 ? "" : "s") waiting", "tray.full") }.buttonStyle(PressScaleStyle()).accessibilityIdentifier("vaultReview")
                }
                NavigationLink(value: Route.moments) {
                    let mine = env.stories.stories(includeReceived: false).count
                    let received = env.stories.received().count
                    shortcutRow("Moments", mine + received == 0 ? "Turn photos into a story worth sharing" : "\(mine) made" + (received > 0 ? " · \(received) shared with you" : ""), "sparkles.rectangle.stack")
                }.buttonStyle(PressScaleStyle()).accessibilityIdentifier("vaultMoments")
                HStack(spacing: MSpacing.s) {
                    tile("Plans", "map", .plans, env.storage.fetchPlans().filter { $0.status.isActive }.count)
                    tile("Promises", "hand.raised", .promises, env.storage.fetchPromises().filter { $0.status == .pending }.count)
                    tile("Gifts", "gift", .gifts, env.storage.fetchGiftIdeas().filter { $0.status.isOpen }.count)
                }
                let pinned = memories.filter(\.isPinned)
                if !pinned.isEmpty { NavigationLink(value: Route.pinned) { shortcutRow("Important", "\(pinned.count) pinned", "star") }.buttonStyle(PressScaleStyle()) }
                let insights = env.storage.fetchInsights().count
                if insights > 0 { NavigationLink(value: Route.insights) { shortcutRow("Tidy up", "\(insights) suggestion\(insights == 1 ? "" : "s")", "wand.and.stars") }.buttonStyle(PressScaleStyle()) }
                NavigationLink(value: Route.stats) { shortcutRow("Your memory", "\(env.storage.memoryCount) Moments · \(env.storage.fetchPeople().count) people", "chart.bar") }.buttonStyle(PressScaleStyle())

                if memories.isEmpty {
                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        Text("Your archive fills in as you capture.").font(MFont.headline)
                        Text("Every Moment lands here with its source, in the order it happened.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                    }.momentCard()
                } else {
                    ForEach(months, id: \.self) { month in
                        VStack(alignment: .leading, spacing: MSpacing.s) {
                            Text(month.monthYear).font(MFont.title).tracking(-0.3).padding(.top, MSpacing.m)
                            let items = (groups[month] ?? []).sorted { $0.createdAt > $1.createdAt }
                            VStack(spacing: 0) {
                                ForEach(items) { m in
                                    NavigationLink(value: Route.memory(m.id)) { TimelineRow(memory: m) }.buttonStyle(.plain)
                                    if m.id != items.last?.id { Divider().padding(.leading, 40) }
                                }
                            }
                            .momentCard(padding: MSpacing.m)
                        }
                    }
                }
            }
            .padding(.horizontal, MSpacing.l)
            .padding(.bottom, MSpacing.xxl)
        }
        .background(AmbientBackdrop(intensity: 0.5).ignoresSafeArea())
        .navigationTitle(embedded ? "Timeline" : "")
        .toolbarVisibility(embedded ? .visible : .hidden, for: .navigationBar)
        .task { reload() }
        .onChange(of: env.surface.changeToken) { _, _ in reload() }
    }

    private func reload() { memories = env.storage.fetchMemories() }

    private func tile(_ title: String, _ symbol: String, _ route: Route, _ count: Int) -> some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(MColor.accent)
                    .frame(width: 34, height: 34).background(MColor.accentSoft, in: RoundedRectangle(cornerRadius: MRadius.icon, style: .continuous))
                Text(title).font(MFont.headline)
                Text("\(count) open").font(MFont.caption).foregroundStyle(MColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .momentCard(padding: MSpacing.m)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("\(title), \(count) open")
    }

    private func shortcutRow(_ title: String, _ subtitle: String, _ symbol: String) -> some View {
        HStack(spacing: MSpacing.m) {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(MColor.accent)
                .frame(width: 34, height: 34).background(MColor.accentSoft, in: RoundedRectangle(cornerRadius: MRadius.icon, style: .continuous))
            VStack(alignment: .leading, spacing: 2) { Text(title).font(MFont.headline); Text(subtitle).font(MFont.caption).foregroundStyle(MColor.textSecondary) }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(MColor.textTertiary)
        }
        .momentCard(padding: MSpacing.m)
    }
}

/// Newly captured content waits here. Bulk-approve the obvious ones.
struct ReviewView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var items: [Memory] = []

    var body: some View {
        Group {
            if items.isEmpty {
                EmptyStateView(symbol: "tray", title: "All reviewed.", message: "New Moments land here first — already understood. Share a screenshot to MOMENT from any app and it will show up here.")
            } else {
                List {
                    Section {
                        ForEach(items) { m in
                            VStack(alignment: .leading, spacing: MSpacing.s) {
                                MemoryRow(memory: m)
                                HStack(spacing: MSpacing.s) {
                                    Button("Save", action: { save(m) }).buttonStyle(ChipButtonStyle(prominent: true)).accessibilityIdentifier("inboxSave")
                                    Button("Dismiss", action: { dismiss(m) }).buttonStyle(ChipButtonStyle())
                                    Spacer()
                                    ConfidenceBadge(confidence: m.confidence)
                                }
                            }
                            .padding(.vertical, 4)
                            .background { NavigationLink(value: Route.memory(m.id)) { EmptyView() }.opacity(0) }
                            .swipeActions(edge: .trailing) { Button("Dismiss", role: .destructive) { dismiss(m) } }
                            .swipeActions(edge: .leading) { Button("Save") { save(m) }.tint(MColor.success) }
                        }
                    } header: { Text("\(items.count) new Moment\(items.count == 1 ? "" : "s")") }
                }
                .scrollContentBackground(.hidden)
                .background(AmbientBackdrop(intensity: 0.4).ignoresSafeArea())
            }
        }
        .navigationTitle("Review")
        .toolbar { if items.count > 1 { ToolbarItem(placement: .primaryAction) { Button("Save all") { saveAll() }.accessibilityIdentifier("inboxSaveAll") } } }
        .task { reload() }
        .refreshable { await env.shareInbox.drain(); reload() }
        .onChange(of: env.surface.changeToken) { _, _ in reload() }
    }

    private func reload() { items = env.storage.fetchInbox() }
    private func save(_ m: Memory) { env.actions.save(m); Haptics.saved(); env.toast("Saved."); reload(); Task { await env.surface.refresh() } }
    private func saveAll() { env.actions.saveAll(items); Haptics.saved(); env.toast("Saved \(items.count)."); reload(); Task { await env.surface.refresh() } }
    private func dismiss(_ m: Memory) { env.actions.dismiss(m); reload() }
}

struct PinnedView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        let pinned = env.storage.fetchMemories().filter(\.isPinned)
        ScrollView {
            VStack(spacing: MSpacing.m) {
                if pinned.isEmpty { Text("Mark a memory important and it will live here.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary).momentCard() }
                ForEach(pinned) { m in NavigationLink(value: Route.memory(m.id)) { MomentCard(memory: m, compact: true) }.buttonStyle(.plain) }
            }.padding(MSpacing.l)
        }
        .background(AmbientBackdrop(intensity: 0.4).ignoresSafeArea())
        .navigationTitle("Important")
    }
}

/// Secondary, honest numbers. The one that matters: Moments MOMENT brought back that you acted on.
struct MemoryStatsView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        let memories = env.storage.fetchMemories(includeArchived: true)
        let people = env.storage.fetchPeople().filter { !$0.visibleMemories.isEmpty }
        let plans = env.storage.fetchPlans().filter { $0.status.isActive }
        let promises = env.storage.fetchPromises().filter { $0.status == .pending }
        let gifts = env.storage.fetchGiftIdeas().filter { $0.status.isOpen }
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("Memories remembered").eyebrowStyle()
                    Text("\(env.surface.resurfacedThisMonth())").font(.system(size: 56, weight: .bold, design: .rounded)).tracking(-1)
                    Text("Moments MOMENT brought back this month that you acted on.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                    Text("\(env.storage.profile().usefulMemoriesResurfaced) all time").font(MFont.caption).foregroundStyle(MColor.textTertiary)
                }.momentCard()
                VStack(spacing: MSpacing.m) {
                    stat("Moments", memories.count)
                    stat("People", people.count)
                    stat("Plans in motion", plans.count)
                    stat("Open promises", promises.count)
                    stat("Gift ideas", gifts.count)
                }.momentCard()
            }.padding(MSpacing.l)
        }
        .background(AmbientBackdrop(intensity: 0.4).ignoresSafeArea())
        .navigationTitle("Your memory")
    }
    private func stat(_ label: String, _ n: Int) -> some View {
        HStack { Text(label).font(MFont.body); Spacer(); Text("\(n)").font(.system(.body, design: .rounded, weight: .semibold)) }.accessibilityElement(children: .combine)
    }
}

/// What Home shows and how much. Kept to a handful of switches.
struct HomeSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section("Density") {
                Picker("Home", selection: $settings.homeDensity) { ForEach(SettingsStore.HomeDensity.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                Text("Balanced shows up to 6 things. Minimal shows 3. Detailed shows 10.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
            Section("Show on Home") {
                Toggle("People", isOn: $settings.showPeopleOnHome)
                Toggle("Plans", isOn: $settings.showPlansOnHome)
                Toggle("Memories from the past", isOn: $settings.showMemoriesOnHome)
                Toggle("Daily brief", isOn: $settings.dailyBriefEnabled)
            }
            Section {
                Button("Reset what MOMENT learned from your feedback") { settings.categoryFeedback = [:]; env.toast("Reset.") }
            } footer: { Text("“Useful” and “Not useful” quietly tune which kinds of Moments show up first.") }
        }
        .navigationTitle("Home")
        .onChange(of: settings.homeDensity) { _, _ in Task { await env.surface.refresh(scheduleNotifications: false) } }
        .onChange(of: settings.showPeopleOnHome) { _, _ in Task { await env.surface.refresh(scheduleNotifications: false) } }
        .onChange(of: settings.showPlansOnHome) { _, _ in Task { await env.surface.refresh(scheduleNotifications: false) } }
        .onChange(of: settings.showMemoriesOnHome) { _, _ in Task { await env.surface.refresh(scheduleNotifications: false) } }
    }
}
