import SwiftUI

// MARK: - Plans

struct PlansListView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showDone = false
    var body: some View {
        let plans = env.storage.fetchPlans().filter { showDone || $0.status.isActive }
        List {
            if plans.isEmpty { Text("No plans yet. Say “let's go to Goa in December” and MOMENT will keep it as an intention.").foregroundStyle(MColor.textSecondary) }
            ForEach(plans) { plan in
                NavigationLink(value: Route.plan(plan.id)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plan.title).font(MFont.headline)
                        HStack(spacing: 6) {
                            ContextPill(text: plan.status.label, tone: plan.status == .planned ? .success : .accent)
                            if let when = TemporalFormatter.describe(start: plan.anchorDate, end: plan.possibleDateEnd, precision: plan.confirmedDate != nil ? .day : plan.possiblePrecision) { Text(when).font(MFont.caption).foregroundStyle(MColor.textSecondary) }
                            if !plan.people.isEmpty { Text("· \(plan.people.map(\.displayName).joined(separator: ", "))").font(MFont.caption).foregroundStyle(MColor.textSecondary) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AmbientBackdrop(intensity: 0.4).ignoresSafeArea())
        .navigationTitle("Plans")
        .toolbar { ToolbarItem(placement: .primaryAction) { Toggle("Show finished", isOn: $showDone).toggleStyle(.button).font(.caption) } }
    }
}

/// A plan page: where it stands, what's missing, the one next step, and how it came together.
struct PlanDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let planID: UUID
    @State private var showDatePicker = false
    @State private var date = Date.now
    @State private var openEditor: UUID?

    var body: some View {
        if let plan = env.storage.plan(id: planID) { content(plan).navigationDestination(item: $openEditor) { id in MomentEditorView(storyID: id) } } else { EmptyStateView(symbol: "map", title: "That plan is gone", message: "") }
    }

    private func content(_ plan: Plan) -> some View {
        let memories = plan.memories.filter { !$0.isDeleted }.sorted { $0.createdAt < $1.createdAt }
        let assessment = PlanIntelligence.assess(status: plan.status, hasDate: plan.anchorDate != nil, exactDate: plan.confirmedDate != nil || plan.possiblePrecision == .day || plan.possiblePrecision == .exact, peopleCount: plan.people.count, memoryTexts: memories.map(\.content), relatedCount: memories.count)
        let when = TemporalFormatter.describe(start: plan.anchorDate, end: plan.possibleDateEnd, precision: plan.confirmedDate != nil ? .day : plan.possiblePrecision)
        return ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    HStack(spacing: 6) { Image(systemName: "map").font(.caption.weight(.semibold)).foregroundStyle(MColor.accent); Text("Plan · \(assessment.stage)").eyebrowStyle() }
                    Text(plan.title).displayStyle()
                    Text(when.map { plan.confirmedDate != nil ? "Confirmed for \($0)." : "You mentioned \($0)." } ?? "No date yet.").font(MFont.body).foregroundStyle(MColor.textSecondary)
                    if let first = memories.first { Text("First came up \(first.createdAt.formatted(.dateTime.month(.wide).day())).").font(MFont.footnote).foregroundStyle(MColor.textTertiary) }
                }

                if assessment.isComingTogether, plan.status.isActive {
                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        Text("\(plan.title) is coming together.").font(MFont.title).tracking(-0.3)
                        Text("\(assessment.relatedCount) related memories" + (plan.people.isEmpty ? "." : " · \(plan.people.map(\.displayName).joined(separator: ", "))")).font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                    }.momentCard()
                }

                // Next best action + what's missing. Never auto-filled.
                if plan.status.isActive {
                    VStack(alignment: .leading, spacing: MSpacing.m) {
                        Text("Next").eyebrowStyle()
                        Text(assessment.nextAction).font(MFont.title).tracking(-0.3)
                        if !assessment.missing.isEmpty {
                            Text("Want to finish this plan?").font(MFont.subheadline.weight(.semibold))
                            FlowLayout(spacing: 8) { ForEach(assessment.missing, id: \.self) { ContextPill(text: "Missing: \($0)", tone: .warning) } }
                        }
                        HStack(spacing: MSpacing.s) {
                            if plan.status == .idea || plan.status == .discussed { Button("Make this a plan") { env.actions.setStatus(plan, .tentative); Haptics.saved(); env.toast("It's a plan.") }.buttonStyle(ChipButtonStyle(prominent: true)) }
                            Button(plan.confirmedDate == nil ? "Pick dates" : "Change dates") { date = plan.anchorDate ?? .now; showDatePicker = true }.buttonStyle(ChipButtonStyle(prominent: plan.status != .idea && plan.status != .discussed))
                            if plan.status == .tentative { Button("Confirm") { env.actions.setStatus(plan, .planned); env.toast("Confirmed.") }.buttonStyle(ChipButtonStyle()) }
                        }
                    }.momentCard()
                }

                if !plan.people.isEmpty {
                    VStack(alignment: .leading, spacing: MSpacing.m) {
                        Text("With").eyebrowStyle()
                        ForEach(plan.people) { p in NavigationLink(value: Route.person(p.id)) { HStack { PersonAvatar(name: p.displayName, size: 30); Text(p.displayName); Spacer(); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(MColor.textTertiary) } }.buttonStyle(.plain) }
                    }.momentCard()
                }

                // Before you go: everything saved that's connected.
                VStack(alignment: .leading, spacing: MSpacing.m) {
                    Text(plan.status.isActive ? "Before \(plan.title)" : "How it came together").eyebrowStyle()
                    if memories.isEmpty { Text("Nothing linked yet.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary) }
                    ForEach(memories) { m in NavigationLink(value: Route.memory(m.id)) { MemoryRow(memory: m) }.buttonStyle(.plain) }
                    if memories.count >= 2 {
                        Button(plan.people.isEmpty ? "Make this shareable" : "Share with \(plan.people.map(\.displayName).joined(separator: ", "))") {
                            if let s = env.stories.planStory(plan) { openEditor = s.id }
                        }.buttonStyle(ChipButtonStyle(prominent: true))
                    }
                }.momentCard()

                VStack(alignment: .leading, spacing: MSpacing.m) {
                    Text("Status").eyebrowStyle()
                    Picker("Status", selection: Binding(get: { plan.status }, set: { env.actions.setStatus(plan, $0) })) {
                        ForEach(PlanStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.menu)
                }.momentCard()
            }
            .padding(MSpacing.l)
        }
        .background(AmbientBackdrop(intensity: 0.5).ignoresSafeArea())
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDatePicker) {
            NavigationStack {
                DatePicker("Date", selection: $date, displayedComponents: .date).datePickerStyle(.graphical).padding()
                    .navigationTitle("When?").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Set") { env.actions.setConfirmedDate(plan, date); showDatePicker = false; env.toast("Dates set.") } } }
            }.presentationDetents([.medium])
        }
    }
}

// MARK: - Promises

/// "Things people owe me" / "Things I owe people".
struct PromisesListView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showDone = false
    var body: some View {
        let promises = env.storage.fetchPromises().filter { showDone || $0.status == .pending }
        let theyOwe = promises.filter { $0.direction != .userOwes }
        let iOwe = promises.filter { $0.direction == .userOwes }
        List {
            if promises.isEmpty {
                Text("Nothing open. When someone says “I'll send you…”, MOMENT keeps track.").foregroundStyle(MColor.textSecondary)
            }
            if !theyOwe.isEmpty {
                Section("Things people owe me") { ForEach(theyOwe) { promiseRow($0) } }
            }
            if !iOwe.isEmpty {
                Section("Things I owe people") { ForEach(iOwe) { promiseRow($0) } }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AmbientBackdrop(intensity: 0.4).ignoresSafeArea())
        .navigationTitle("Promises")
        .toolbar { ToolbarItem(placement: .primaryAction) { Toggle("Show done", isOn: $showDone).toggleStyle(.button).font(.caption) } }
    }

    private func promiseRow(_ p: Promise) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(p.person?.displayName ?? (p.direction == .userOwes ? "You" : "Someone")).font(MFont.caption.weight(.semibold)).foregroundStyle(MColor.accent)
                Text(p.summary.capitalizedFirst).font(MFont.headline)
                HStack(spacing: 6) {
                    if p.isOverdue, let due = p.dueDate { ContextPill(text: "\(max(1, due.daysUntil(.now))) day\(due.daysUntil(.now) == 1 ? "" : "s") overdue", tone: .warning) }
                    else if let due = p.dueDate, p.status == .pending { ContextPill(text: due.relativeDescription, symbol: "calendar", tone: .accent) }
                    else { Text(p.createdAt.relativeDescription).font(MFont.caption).foregroundStyle(MColor.textTertiary) }
                    if p.status != .pending { ContextPill(text: p.status.label, tone: .success) }
                }
            }
            Spacer()
            if p.status == .pending { Button("Done") { env.actions.complete(p); Haptics.completed(); env.toast("Done.") }.buttonStyle(ChipButtonStyle(prominent: true)) }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background { if let m = p.sourceMemory { NavigationLink(value: Route.memory(m.id)) { EmptyView() }.opacity(0) } }
        .swipeActions(edge: .leading) { if p.status == .pending { Button("Done") { env.actions.complete(p); Haptics.completed() }.tint(MColor.success) } }
    }
}

// MARK: - Gift ideas

/// Grouped by person, each with "Why this?" — always the person's own words.
struct GiftIdeasListView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var whyGift: GiftIdea?
    var body: some View {
        let gifts = env.storage.fetchGiftIdeas().filter { $0.status.isOpen }
        let groups = Dictionary(grouping: gifts) { $0.person?.displayName ?? "Unassigned" }
        let names = groups.keys.sorted()
        List {
            if gifts.isEmpty { Text("No gift ideas yet. When someone says “I really want…”, MOMENT saves it for their birthday.").foregroundStyle(MColor.textSecondary) }
            ForEach(names, id: \.self) { name in
                Section {
                    ForEach(groups[name] ?? []) { g in giftRow(g) }
                } header: {
                    HStack {
                        Text(name)
                        if let b = groups[name]?.first?.person?.birthday {
                            let d = Date.now.daysUntil(Event(title: "", date: b, isAnnual: true).nextOccurrence())
                            Text("· birthday in \(d) days").foregroundStyle(d <= 14 ? MColor.warning : MColor.textSecondary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AmbientBackdrop(intensity: 0.4).ignoresSafeArea())
        .navigationTitle("Gift ideas")
        .sheet(item: $whyGift) { g in
            WhySheet(title: g.item, explanation: "\(g.person?.displayName ?? "Someone") mentioned it directly on \(g.dateMentioned.mediumDate): “\(g.details.truncated(160))”", source: g.sourceMemory.map { ($0.sourceType, $0.createdAt) })
        }
    }

    private func giftRow(_ g: GiftIdea) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(g.item).font(MFont.headline)
                HStack(spacing: 8) {
                    Text("Mentioned \(g.dateMentioned.shortDate)").font(MFont.caption).foregroundStyle(MColor.textTertiary)
                    Button("Why this?") { whyGift = g }.font(MFont.caption.weight(.semibold)).buttonStyle(.plain).foregroundStyle(MColor.accent)
                }
            }
            Spacer()
            if let url = g.url { Link(destination: url) { Image(systemName: "bag") }.accessibilityLabel("Shop") }
            Menu { Button("Got it") { env.actions.setStatus(g, .purchased); env.toast("Marked as bought.") }; Button("Given") { env.actions.setStatus(g, .given) }; Button("Dismiss", role: .destructive) { env.actions.setStatus(g, .dismissed) } } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Gift actions")
        }
        .padding(.vertical, 2)
        .background { if let m = g.sourceMemory { NavigationLink(value: Route.memory(m.id)) { EmptyView() }.opacity(0) } }
    }
}
