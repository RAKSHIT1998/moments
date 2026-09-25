import SwiftUI

/// Immersive memory page: large title, "first mentioned", the facts as sections, related memories,
/// why it matters, original / extracted / interpretation, and one bottom call to action.
struct MemoryDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let memoryID: UUID
    @State private var showEdit = false
    @State private var showDelete = false
    @State private var showPersonPicker = false
    @State private var showReminder = false
    @State private var showWhy = false
    @State private var originalMode: OriginalMode = .interpretation
    @State private var image: UIImage?
    @State private var showCalendarConfirm = false

    enum OriginalMode: String, CaseIterable { case interpretation = "Understood", extracted = "Text", original = "Original" }

    private var memory: Memory? { env.storage.memory(id: memoryID) }

    var body: some View {
        if let m = memory { content(m) } else {
            EmptyStateView(symbol: "questionmark.circle", title: "That memory is gone", message: "It may have been deleted.")
        }
    }

    private func content(_ m: Memory) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                header(m)
                if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 280).clipShape(RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous)).accessibilityLabel("Original screenshot") }
                if m.reviewStatus == .needsReview { reviewBar(m) }
                quickActions(m)
                coreMemory(m)
                facts(m)
                whyCard(m)
                related(m)
                original(m)
                history(m)
            }
            .padding(MSpacing.l)
            .padding(.bottom, MSpacing.xxl)
        }
        .background(AmbientBackdrop(intensity: 0.5).ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                    Button { env.actions.togglePin(m); env.toast(m.isPinned ? "Marked important." : "Unmarked.") } label: { Label(m.isPinned ? "Unmark important" : "Mark important", systemImage: m.isPinned ? "star.slash" : "star") }
                    Button { env.actions.archive(m, !m.isArchived) } label: { Label(m.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") }
                    Button(role: .destructive) { showDelete = true } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("More actions")
            }
        }
        .safeAreaInset(edge: .bottom) { bottomCTA(m) }
        .sheet(isPresented: $showEdit) { MemoryEditView(memory: m) }
        .sheet(isPresented: $showReminder) { ReminderSheet(memory: m) }
        .sheet(isPresented: $showPersonPicker) { PersonPickerSheet(memory: m) }
        .sheet(isPresented: $showWhy) { WhySheet(title: m.title, explanation: whyText(m), source: m.source.map { ($0.type, m.createdAt) }) }
        .confirmationDialog("Delete this Moment?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await env.actions.delete(m); dismiss() } }
        } message: { Text("This removes the memory and its stored source from this iPhone.") }
        .task { if let ref = m.imagePath { image = await env.media.loadImage(ref) } }
    }

    // MARK: Sections

    private func header(_ m: Memory) -> some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            HStack(spacing: 6) {
                Image(systemName: m.memoryType.symbol).font(.caption.weight(.semibold)).foregroundStyle(MColor.accent)
                Text(m.memoryType.label).eyebrowStyle()
                if m.isDemo { ContextPill(text: "Example", symbol: "flask") }
                Spacer()
                ConfidenceBadge(confidence: m.confidence)
            }
            Text(m.title).displayStyle().accessibilityIdentifier("memoryDetailTitle")
            Text(firstMentioned(m)).font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
            if m.confidence != .high { Text(confidencePhrase(m)).font(MFont.footnote).foregroundStyle(MColor.warning) }
        }
    }

    private func firstMentioned(_ m: Memory) -> String {
        let who = m.people.first?.displayName
        let when = m.createdAt.formatted(.dateTime.month(.wide).day())
        switch m.sourceType {
        case .screenshot: return who.map { "From a chat with \($0) · \(when)" } ?? "From a screenshot · \(when)"
        case .voice: return "You said this on \(when)"
        case .shareSheet: return "Shared to MOMENT on \(when)"
        default: return "You first mentioned this on \(when)"
        }
    }

    private func confidencePhrase(_ m: Memory) -> String {
        switch m.confidence {
        case .medium: return "I'm fairly sure about this. Tap anything that's off to fix it."
        case .low: return "I'm not sure about this one — check the person and type."
        case .high: return ""
        }
    }

    private func reviewBar(_ m: Memory) -> some View {
        HStack {
            Text("Not saved yet").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
            Spacer()
            Button("Save Moment") { env.actions.save(m); Haptics.saved(); env.toast("Saved."); Task { await env.surface.refresh() } }.buttonStyle(ChipButtonStyle(prominent: true))
            Button("Dismiss") { env.actions.dismiss(m); dismiss() }.buttonStyle(ChipButtonStyle())
        }
        .momentCard(padding: MSpacing.m)
    }

    private func quickActions(_ m: Memory) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MSpacing.s) {
                if let p = m.promises.first(where: { !$0.isDeleted }) {
                    if p.status == .pending { Button("Mark done") { env.actions.complete(p); env.surface.recordUsefulResurface(m); Haptics.completed(); env.toast("Done.") }.buttonStyle(ChipButtonStyle(prominent: true)) }
                    else { Button("Reopen") { env.actions.reopen(p) }.buttonStyle(ChipButtonStyle()) }
                }
                if m.memoryType == .task, m.metadata["completedAt"] == nil { Button("Done") { env.actions.completeTask(m); Haptics.completed(); env.toast("Done.") }.buttonStyle(ChipButtonStyle(prominent: true)) }
                if let g = m.giftIdeas.first(where: { !$0.isDeleted }) {
                    if let url = g.url ?? m.sourceURL { Link("Shop", destination: url).buttonStyle(ChipButtonStyle()) }
                    if g.status.isOpen { Button("Got it") { env.actions.setStatus(g, .purchased); env.toast("Marked as bought.") }.buttonStyle(ChipButtonStyle()) }
                }
                if let e = m.events.first(where: { !$0.isDeleted }), env.settings.calendarConnected, e.calendarEventIdentifier == nil {
                    Button("Add to Calendar") { showCalendarConfirm = true }.buttonStyle(ChipButtonStyle())
                        .confirmationDialog("Add “\(e.title)” to your calendar?", isPresented: $showCalendarConfirm, titleVisibility: .visible) {
                            Button("Add") { if let id = try? env.calendar.addEvent(title: e.title, date: e.nextOccurrence(), isAllDay: e.precision != .exact, notes: "From MOMENT") { e.calendarEventIdentifier = id; env.storage.save(); env.toast("Added to Calendar.") } }
                        }
                }
                Button("Remind me") { showReminder = true }.buttonStyle(ChipButtonStyle())
                Button("Edit") { showEdit = true }.buttonStyle(ChipButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func facts(_ m: Memory) -> some View {
        let people = m.people.filter { !$0.isDeleted }
        let places = m.places.filter { !$0.isDeleted }
        let when = TemporalFormatter.describe(start: m.referencedDateStart, end: m.referencedDateEnd, precision: m.referencedPrecision)
        if !people.isEmpty || m.memoryType == .giftIdea || m.memoryType == .promise {
            section("People") {
                ForEach(people) { p in
                    NavigationLink(value: Route.person(p.id)) {
                        HStack { PersonAvatar(name: p.displayName, size: 32); Text(p.displayName).font(MFont.body); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(MColor.textTertiary) }
                    }.buttonStyle(.plain)
                }
                Button(people.isEmpty ? "Add person" : "Not the right person?") { showPersonPicker = true }.font(.subheadline.weight(.semibold))
            }
        }
        if when != nil || !places.isEmpty || !m.plans.isEmpty || !m.promises.isEmpty || !m.giftIdeas.isEmpty || !m.events.isEmpty {
            section("Details") {
                if let when { LabeledRow(label: "When", value: when.capitalizedFirst, symbol: "calendar") }
                ForEach(places) { p in LabeledRow(label: "Place", value: p.name + (p.kind == "unknown" ? "" : " · \(p.kind)"), symbol: "mappin") }
                ForEach(m.promises.filter { !$0.isDeleted }) { p in LabeledRow(label: p.direction == .userOwes ? "You owe" : "They owe", value: "\(p.summary.capitalizedFirst) · \(p.status.label)", symbol: "hand.raised") }
                ForEach(m.giftIdeas.filter { !$0.isDeleted }) { g in LabeledRow(label: "Gift idea", value: "\(g.item)\(g.person.map { " for \($0.displayName)" } ?? "") · \(g.status.label)", symbol: "gift") }
                ForEach(m.plans.filter { !$0.isDeleted }) { p in NavigationLink(value: Route.plan(p.id)) { LabeledRow(label: "Plan", value: "\(p.title) · \(p.status.label)", symbol: "map") }.buttonStyle(.plain) }
                ForEach(m.events.filter { !$0.isDeleted }) { e in LabeledRow(label: "Event", value: e.isAnnual ? e.date.formatted(.dateTime.month(.wide).day()) + " · every year" : e.date.mediumDate, symbol: "calendar") }
            }
        }
    }

    @ViewBuilder
    private func coreMemory(_ m: Memory) -> some View {
        let verdict = CoreMemoryDetector.assess(env.stories.storyMemory(m), relatedCount: env.storage.fetchRelations(for: m.id).count, mentionsOfSamePlace: m.places.first.map { $0.memories.count } ?? 0)
        if env.flags.isOn(.coreMemoryHints), verdict.isLikely, !m.isPinned, m.metadata["notCore"] != "true" {
            VStack(alignment: .leading, spacing: MSpacing.s) {
                Text("This looks like a core memory.").font(MFont.headline)
                Text(verdict.reasons.prefix(2).joined(separator: " ")).font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                HStack(spacing: MSpacing.s) {
                    Button("Remember this") { env.actions.togglePin(m); env.surface.recordUsefulResurface(m); env.toast("Remembered.") }.buttonStyle(ChipButtonStyle(prominent: true))
                    Button("Not important") { m.metadata["notCore"] = "true"; env.storage.save() }.buttonStyle(ChipButtonStyle())
                }
            }.momentCard()
        }
    }

    private func whyCard(_ m: Memory) -> some View {
        Button { showWhy = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Why MOMENT thinks this matters").font(MFont.subheadline.weight(.semibold))
                    Text(whyText(m)).font(MFont.footnote).foregroundStyle(MColor.textSecondary).lineLimit(2)
                }
                Spacer()
                Image(systemName: "questionmark.circle").foregroundStyle(MColor.accent)
            }
            .momentCard(padding: MSpacing.m)
        }
        .buttonStyle(.plain)
    }

    private func whyText(_ m: Memory) -> String {
        if m.content.lowercased().contains("remind me") { return "You explicitly said “remind me”." }
        if let p = m.promises.first, p.status == .pending { return "\(p.direction == .userOwes ? "You" : (p.person?.displayName ?? "Someone")) said they'd \(p.summary) — and it's still open." }
        if let e = m.events.first { let d = Date.now.daysUntil(e.nextOccurrence()); return d >= 0 && d <= 30 ? "Your saved event is \(d == 0 ? "today" : "in \(d) days")." : "You saved a dated event." }
        if let g = m.giftIdeas.first { return "\(g.person?.displayName ?? "Someone") mentioned wanting \(g.item) directly. Saved as a gift idea." }
        if let p = m.plans.first { return TemporalFormatter.describe(start: p.anchorDate, end: p.possibleDateEnd, precision: p.possiblePrecision).map { "You talked about \(p.title) for \($0)." } ?? "You talked about \(p.title) as a plan." }
        if m.memoryType == .task { return "You said you need to do this." }
        if m.isPinned { return "You marked this important." }
        return "You captured it, and MOMENT keeps every source. Importance \(m.importance)/100."
    }

    @ViewBuilder
    private func related(_ m: Memory) -> some View {
        let rel = relatedMemories(m)
        if !rel.isEmpty {
            section("Related") {
                ForEach(rel, id: \.0.id) { relation, other in
                    NavigationLink(value: Route.memory(other.id)) { MemoryRow(memory: other, reason: relation.reason) }.buttonStyle(.plain)
                        .contextMenu { Button("Remove link", role: .destructive) { env.actions.removeRelation(relation) } }
                }
            }
        }
    }

    private func original(_ m: Memory) -> some View {
        section("Source") {
            if let s = m.source { SourceBadge(type: s.type, date: m.createdAt) }
            Picker("View", selection: $originalMode) { ForEach(OriginalMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            switch originalMode {
            case .interpretation:
                Text(m.summary.isBlank ? m.title : m.summary).font(MFont.body)
                if let ev = m.metadata["evidence"], !ev.isBlank { Text("Based on: “\(ev)”").font(MFont.footnote).foregroundStyle(MColor.textSecondary) }
            case .extracted:
                Text(m.content.isBlank ? "No text was extracted." : m.content).font(MFont.footnote).foregroundStyle(MColor.textSecondary).textSelection(.enabled)
            case .original:
                Text(m.source?.originalText ?? m.content).font(MFont.footnote).foregroundStyle(MColor.textSecondary).textSelection(.enabled)
                if let url = m.sourceURL { Link(destination: url) { Label(url.host() ?? url.absoluteString, systemImage: "link") }.font(MFont.footnote) }
            }
        }
    }

    @ViewBuilder
    private func history(_ m: Memory) -> some View {
        let events = editHistory(m)
        if events.count > 1 {
            section("History") {
                ForEach(events, id: \.self) { Text($0).font(MFont.footnote).foregroundStyle(MColor.textSecondary) }
            }
        }
    }

    private func editHistory(_ m: Memory) -> [String] {
        var out = ["Created \(m.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(m.sourceType.label)"]
        if m.metadata["userEdited"] == "true" { out.append("Edited \(m.updatedAt.formatted(date: .abbreviated, time: .shortened))") }
        if m.metadata["correctedPerson"] != nil { out.append("Person corrected") }
        if env.storage.fetchRelations(for: m.id).contains(where: { $0.kind == .mergedFrom }) { out.append("Merged from other captures") }
        if let c = m.metadata["completedAt"] { out.append("Completed \(c.prefix(10))") }
        return out
    }

    private func bottomCTA(_ m: Memory) -> some View {
        Group {
            if let plan = m.plans.first(where: { !$0.isDeleted }) {
                NavigationLink(value: Route.plan(plan.id)) { Text(plan.status == .idea || plan.status == .discussed ? "Make this a plan" : "Open plan") }
                    .buttonStyle(PrimaryButtonStyle()).padding(.horizontal, MSpacing.page).padding(.vertical, MSpacing.m).background(.bar)
            } else if m.memoryType == .idea || m.places.contains(where: { EntityRecognizer.knownDestinations.contains($0.name.lowercased()) }) {
                Button("Turn into a plan") { turnIntoPlan(m) }.buttonStyle(PrimaryButtonStyle()).padding(.horizontal, MSpacing.page).padding(.vertical, MSpacing.m).background(.bar)
            }
        }
    }

    private func turnIntoPlan(_ m: Memory) {
        let plan = Plan(title: m.places.first?.name ?? m.title, details: m.summary, location: m.places.first?.name, status: .tentative)
        plan.possibleDateStart = m.referencedDateStart; plan.possibleDateEnd = m.referencedDateEnd; plan.possiblePrecision = m.referencedPrecision
        for p in m.people { plan.people.append(p) }
        env.storage.context.insert(plan)
        m.plans.append(plan)
        env.storage.save()
        Haptics.saved()
        env.toast("Plan created.")
    }

    private func relatedMemories(_ m: Memory) -> [(MemoryRelation, Memory)] {
        env.storage.fetchRelations(for: m.id).compactMap { rel in
            let otherID = rel.fromMemoryID == m.id ? rel.toMemoryID : rel.fromMemoryID
            guard let other = env.storage.memory(id: otherID), !other.isDeleted, other.reviewStatus != .dismissed else { return nil }
            return (rel, other)
        }
        .sorted { $0.0.strength > $1.0.strength }
        .prefix(6).map { $0 }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            Text(title).eyebrowStyle()
            content()
        }
        .momentCard()
    }
}
