import SwiftUI
import ContactsUI

/// Contextual profile — only what the user's own captures support. No inferred traits.
struct PersonProfileView: View {
    @Environment(AppEnvironment.self) private var env
    let personID: UUID
    @State private var showEdit = false
    @State private var showContactPicker = false

    private var person: Person? { env.storage.person(id: personID) }

    var body: some View {
        if let p = person { content(p) } else { EmptyStateView(symbol: "person.slash", title: "Not found", message: "This person was removed.") }
    }

    private func content(_ p: Person) -> some View {
        let memories = p.visibleMemories.sorted { $0.createdAt > $1.createdAt }
        let topics = recentTopics(memories)
        let pending = p.pendingPromises
        let plans = p.activePlans
        let gifts = p.openGiftIdeas
        let birthdayDays = p.birthday.map { Date.now.daysUntil(Event(title: "", date: $0, isAnnual: true).nextOccurrence()) }
        let snapshots = memories.map(env.storage.snapshot)
        let insights = PersonInsights.sentences(name: p.displayName, memories: snapshots, pendingPromises: pending.count, openGifts: gifts.count, birthdayInDays: birthdayDays, activePlans: plans.map(\.title))
        let next = PersonInsights.nextAction(pendingPromiseSummary: pending.first.map { ($0.direction == .userOwes ? "you owe " : "") + $0.summary }, birthdayInDays: birthdayDays, openGifts: gifts.count, activePlan: plans.first?.title)
        return ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                HStack(spacing: MSpacing.l) {
                    PersonAvatar(name: p.displayName, size: MIcon.hero)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.displayName).displayStyle().accessibilityIdentifier("personName")
                        if let r = p.statedRelationship { Text(r.capitalizedFirst).font(MFont.subheadline).foregroundStyle(MColor.textSecondary) }
                        if let last = p.lastInteractionAt { Text("Last meaningful Moment · \(last.relativeDescription.lowercased())").font(MFont.caption).foregroundStyle(MColor.textTertiary) }
                    }
                }

                // What matters right now — not the whole history.
                if next != nil || !insights.isEmpty {
                    VStack(alignment: .leading, spacing: MSpacing.m) {
                        Text("Right now").eyebrowStyle()
                        if let next { Text(next).font(MFont.title).tracking(-0.3) }
                        ForEach(insights, id: \.self) { Text($0).font(MFont.body).foregroundStyle(next == nil ? MColor.textPrimary : MColor.textSecondary) }
                        if let first = pending.first {
                            HStack(spacing: MSpacing.s) {
                                Button("Done") { env.actions.complete(first); Haptics.completed(); env.toast("Done.") }.buttonStyle(ChipButtonStyle(prominent: true))
                                if let m = first.sourceMemory { NavigationLink(value: Route.memory(m.id)) { Text("Open") }.buttonStyle(ChipButtonStyle()) }
                            }
                        }
                    }
                    .momentCard()
                }

                if !topics.isEmpty {
                    block("Recent") { FlowLayout(spacing: 8) { ForEach(topics, id: \.self) { TagChip(text: $0) } } }
                }

                if memories.count >= 2 {
                    NavigationLink(value: Route.friendship(p.id)) {
                        HStack(spacing: MSpacing.m) {
                            Image(systemName: "person.2.fill").font(.body.weight(.semibold)).foregroundStyle(MColor.overlayLight).frame(width: 34, height: 34).background(MColor.accentGradient, in: RoundedRectangle(cornerRadius: MRadius.icon, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) { Text("You + \(p.displayName)").font(MFont.headline); Text("\(memories.count) shared moments · make it a Moment").font(MFont.caption).foregroundStyle(MColor.textSecondary) }
                            Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(MColor.textTertiary)
                        }.momentCard(padding: MSpacing.m)
                    }.buttonStyle(PressScaleStyle())
                }

                if let b = p.birthday {
                    block("Upcoming") {
                        HStack { Label("Birthday · \(b.formatted(.dateTime.month(.wide).day()))", systemImage: "birthday.cake").font(MFont.body); Spacer(); if let d = birthdayDays { ContextPill(text: d == 0 ? "Today" : "in \(d) days", tone: d <= 14 ? .warning : .neutral) } }
                    }
                }

                if !gifts.isEmpty {
                    block("Gift ideas") {
                        ForEach(gifts) { g in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) { Text(g.item).font(MFont.body); Text("Mentioned \(g.dateMentioned.relativeDescription.lowercased())").font(MFont.caption).foregroundStyle(MColor.textTertiary) }
                                Spacer()
                                if let url = g.url { Link("Shop", destination: url).buttonStyle(ChipButtonStyle()) }
                            }
                        }
                    }
                }

                if !plans.isEmpty {
                    block("Plans") {
                        ForEach(plans) { plan in
                            NavigationLink(value: Route.plan(plan.id)) {
                                HStack { Text(plan.title).font(MFont.body); Spacer(); Text(TemporalFormatter.describe(start: plan.anchorDate, end: plan.possibleDateEnd, precision: plan.confirmedDate != nil ? .day : plan.possiblePrecision) ?? plan.status.label).font(MFont.caption).foregroundStyle(MColor.textSecondary); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(MColor.textTertiary) }
                            }.buttonStyle(.plain)
                        }
                    }
                }

                if pending.count > 1 {
                    block("Open promises") {
                        ForEach(pending.dropFirst()) { promise in
                            HStack {
                                Text((promise.direction == .userOwes ? "You: " : "") + promise.summary.capitalizedFirst).font(MFont.body)
                                Spacer()
                                Button("Done") { env.actions.complete(promise); Haptics.completed() }.buttonStyle(ChipButtonStyle())
                            }
                        }
                    }
                }

                if !p.notes.isEmpty { block("Your notes") { Text(p.notes).font(MFont.body) } }

                block("Memories") {
                    if memories.isEmpty { Text("No saved memories yet.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary) }
                    ForEach(memories) { m in NavigationLink(value: Route.memory(m.id)) { MemoryRow(memory: m) }.buttonStyle(.plain) }
                }
            }
            .padding(MSpacing.l)
        }
        .background(AmbientBackdrop(intensity: 0.5).ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                    Button { showContactPicker = true } label: { Label(p.contactIdentifier == nil ? "Link to a contact" : "Re-link contact", systemImage: "person.crop.circle.badge.plus") }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("More")
            }
        }
        .sheet(isPresented: $showEdit) { PersonEditView(person: p) }
        .sheet(isPresented: $showContactPicker) { ContactPicker { id in link(p, contactID: id) } }
    }

    private func link(_ p: Person, contactID: String) {
        guard let c = env.contacts.contact(identifier: contactID) else { return }
        p.contactIdentifier = contactID
        if !c.name.isEmpty, c.name.lowercased() != p.displayName.lowercased() { p.aliases = Array(Set(p.aliases + [c.name.lowercased()])) }
        if p.birthday == nil { p.birthday = c.birthday }
        env.storage.save()
    }

    private func recentTopics(_ memories: [Memory]) -> [String] {
        var seen: [String] = []
        for m in memories.prefix(12) {
            for t in m.places.map(\.name) + m.giftIdeas.map(\.item) + m.plans.map(\.title) where !seen.contains(where: { $0.lowercased() == t.lowercased() }) { seen.append(t) }
            if m.memoryType == .personFact || m.memoryType == .idea, seen.count < 6 {
                let t = m.title.truncated(28)
                if !seen.contains(t) { seen.append(t) }
            }
        }
        return Array(seen.prefix(6))
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: MSpacing.m) { Text(title).eyebrowStyle(); content() }.momentCard()
    }
}

struct PersonEditView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let person: Person
    @State private var name: String
    @State private var relationship: String
    @State private var notes: String
    @State private var hasBirthday: Bool
    @State private var birthday: Date
    @State private var showMerge = false

    init(person: Person) {
        self.person = person
        _name = State(initialValue: person.displayName)
        _relationship = State(initialValue: person.statedRelationship ?? "")
        _notes = State(initialValue: person.notes)
        _hasBirthday = State(initialValue: person.birthday != nil)
        _birthday = State(initialValue: person.birthday ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                    TextField("Relationship (optional, e.g. brother)", text: $relationship)
                }
                Section("Birthday") {
                    Toggle("Known", isOn: $hasBirthday)
                    if hasBirthday { DatePicker("Birthday", selection: $birthday, displayedComponents: .date) }
                }
                Section("Notes") { TextField("Anything you want to remember", text: $notes, axis: .vertical).lineLimit(3...8) }
                Section {
                    Button("Merge into another person…") { showMerge = true }
                } footer: { Text("Use this when MOMENT created two people for the same person.") }
            }
            .navigationTitle("Edit person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(name.isBlank) }
            }
            .sheet(isPresented: $showMerge) { MergePersonSheet(duplicate: person) { dismiss() } }
        }
    }

    private func save() {
        env.actions.rename(person, to: name, relationship: relationship.isBlank ? nil : relationship.trimmed.lowercased(), notes: notes, birthday: hasBirthday ? birthday : nil)
        Task { await env.surface.refresh() }
        dismiss()
    }
}

struct MergePersonSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let duplicate: Person
    let onMerged: () -> Void
    var body: some View {
        NavigationStack {
            List(env.storage.fetchPeople().filter { $0.id != duplicate.id }) { p in
                Button { env.actions.merge(person: duplicate, into: p); dismiss(); onMerged() } label: {
                    HStack { PersonAvatar(name: p.displayName, size: 30); Text("Merge into \(p.displayName)") }
                }.foregroundStyle(MColor.textPrimary)
            }
            .navigationTitle("Merge \(duplicate.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// System contact picker — the user chooses exactly one contact; nothing else is read.
struct ContactPicker: UIViewControllerRepresentable {
    let onPick: (String) -> Void
    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let vc = CNContactPickerViewController()
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (String) -> Void
        init(onPick: @escaping (String) -> Void) { self.onPick = onPick }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) { onPick(contact.identifier) }
    }
}

/// Minimal wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
