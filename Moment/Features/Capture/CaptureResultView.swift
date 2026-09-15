import SwiftUI

/// "I found something worth remembering." — the aha moment. Subject / verb / object typography,
/// every extracted fact tappable to correct, one overwhelming action: Save Moment.
struct CaptureResultView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let outcome: ImportService.Outcome
    let onDone: () -> Void
    @State private var editing: Memory?
    @State private var discarded: Set<UUID> = []
    @State private var appeared = false

    private var memories: [Memory] { outcome.memories.filter { !discarded.contains($0.id) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("Got it.").eyebrowStyle()
                    Text(headline).displayStyle().accessibilityIdentifier("captureResultHeadline")
                    Label(outcome.usedRemote ? "Understood with Cloud AI" : "Understood on this iPhone", systemImage: outcome.usedRemote ? "cloud" : "iphone")
                        .font(MFont.caption).foregroundStyle(MColor.textTertiary)
                }
                .padding(.horizontal, MSpacing.l)

                ForEach(outcome.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.circle").font(MFont.footnote).foregroundStyle(MColor.warning).padding(.horizontal, MSpacing.l)
                }

                ForEach(Array(memories.enumerated()), id: \.element.id) { index, m in
                    ExtractedMemoryCard(memory: m, onEdit: { editing = m }, onDiscard: { discard(m) })
                        .padding(.horizontal, MSpacing.l)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared || reduceMotion ? 0 : 12)
                        .animation(reduceMotion ? nil : MAnimation.standard.delay(Double(index) * 0.06), value: appeared)
                }

                if memories.isEmpty {
                    Text("Nothing left to save.").font(MFont.body).foregroundStyle(MColor.textSecondary).padding(.horizontal, MSpacing.l)
                }
            }
            .padding(.vertical, MSpacing.l)
        }
        .background(AmbientBackdrop(intensity: 0.6).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: MSpacing.s) {
                Button(memories.count > 1 ? "Save all \(memories.count)" : "Save Moment") { saveAll() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(memories.isEmpty)
                    .accessibilityIdentifier("captureSave")
                Button("Discard") { discardAll() }.font(MFont.subheadline).foregroundStyle(MColor.textSecondary).frame(minHeight: MTouch.minimum)
            }
            .padding(MSpacing.l)
            .background(.bar)
        }
        .sheet(item: $editing) { m in MemoryEditView(memory: m) }
        .onAppear { appeared = true }
    }

    private var headline: String {
        if memories.isEmpty { return "Nothing to remember." }
        if memories.count == 1 { return "I found something worth remembering." }
        return "I found \(memories.count) Moments."
    }

    private func saveAll() {
        env.actions.saveAll(memories)
        Haptics.saved()
        env.toast(memories.count == 1 ? "I'll remember that." : "Saved \(memories.count) Moments.")
        Task { await env.surface.refresh() }
        onDone()
    }

    private func discard(_ m: Memory) {
        discarded.insert(m.id)
        Task { await env.actions.delete(m) }
    }

    private func discardAll() {
        for m in memories { discarded.insert(m.id) }
        Task { for m in outcome.memories { await env.actions.delete(m) } }
        onDone()
    }
}

/// One understood item: type · subject-verb-object · facts (each tappable) · edit/discard.
struct ExtractedMemoryCard: View {
    @Environment(AppEnvironment.self) private var env
    let memory: Memory
    var onEdit: () -> Void
    var onDiscard: () -> Void
    @State private var showPersonPicker = false
    @State private var showTypePicker = false
    @State private var showWhenPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            HStack {
                Button { showTypePicker = true } label: {
                    HStack(spacing: 4) { Image(systemName: memory.memoryType.symbol); Text(memory.memoryType.label); Image(systemName: "chevron.up.chevron.down").font(.caption2) }
                }
                .buttonStyle(.plain).font(MFont.eyebrow).textCase(.uppercase).tracking(0.9).foregroundStyle(MColor.accent)
                .accessibilityLabel("Type: \(memory.memoryType.label). Double-tap to change.")
                Spacer()
                ConfidenceBadge(confidence: memory.confidence)
            }

            headlineBlock

            VStack(spacing: MSpacing.s) {
                if let person = memory.people.first {
                    factRow("Person", person.displayName, symbol: "person") { showPersonPicker = true }
                } else if [.giftIdea, .promise, .personFact].contains(memory.memoryType) || memory.confidence == .low {
                    factRow("Person", "Add who", symbol: "person.badge.plus") { showPersonPicker = true }
                }
                if let g = memory.giftIdeas.first { factRow("Wants", g.item, symbol: "gift", action: onEdit) }
                if let p = memory.promises.first { factRow(p.direction == .userOwes ? "You owe" : "They owe", p.summary.capitalizedFirst, symbol: "hand.raised", action: onEdit) }
                if let pl = memory.plans.first { factRow("Plan", pl.title, symbol: "map", action: onEdit) }
                if !memory.places.isEmpty {
                    let names = memory.places.map(\.name)
                    let shown = names.filter { n in !names.contains { $0 != n && $0.localizedCaseInsensitiveContains(n) } }
                    factRow("Place", shown.joined(separator: ", "), symbol: "mappin", action: onEdit)
                }
                factRow("When", TemporalFormatter.describe(start: memory.referencedDateStart, end: memory.referencedDateEnd, precision: memory.referencedPrecision)?.capitalizedFirst ?? "No date", symbol: "calendar") { showWhenPicker = true }
                if let s = memory.source { factRow("Source", "\(s.type.label) · \(memory.createdAt.relativeDescription)", symbol: s.type.symbol) }
            }

            HStack(spacing: MSpacing.s) {
                Button("Edit", action: onEdit).buttonStyle(ChipButtonStyle())
                Button("Discard", action: onDiscard).buttonStyle(ChipButtonStyle())
                Spacer()
            }
        }
        .momentCard()
        .sheet(isPresented: $showPersonPicker) { PersonPickerSheet(memory: memory) }
        .sheet(isPresented: $showWhenPicker) { WhenPickerSheet(memory: memory) }
        .confirmationDialog("What is this?", isPresented: $showTypePicker, titleVisibility: .visible) {
            ForEach([MemoryType.giftIdea, .promise, .plan, .task, .event, .place, .personFact, .idea, .reference], id: \.self) { t in
                Button(t.label) { env.actions.update(memory, title: memory.title, summary: memory.summary, type: t) }
            }
        }
    }

    /// "Sarah / wants / New Balance 530" for gifts; otherwise the title.
    @ViewBuilder
    private var headlineBlock: some View {
        if memory.memoryType == .giftIdea, let g = memory.giftIdeas.first, let who = g.person?.displayName ?? memory.people.first?.displayName {
            VStack(alignment: .leading, spacing: 2) {
                Text(who).font(MFont.title).tracking(-0.3)
                Text("wants").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                Text(g.item).font(MFont.title).tracking(-0.3)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(who) wants \(g.item)")
            .accessibilityIdentifier("extractedTitle")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(memory.title).font(MFont.title).tracking(-0.3).accessibilityIdentifier("extractedTitle")
                if !memory.summary.isEmpty, memory.summary != memory.title { Text(memory.summary).font(MFont.body).foregroundStyle(MColor.textSecondary) }
            }
        }
    }

    private func factRow(_ label: String, _ value: String, symbol: String, action: (() -> Void)? = nil) -> some View {
        HStack {
            Label(label, systemImage: symbol).font(MFont.subheadline).foregroundStyle(MColor.textSecondary).frame(width: 110, alignment: .leading)
            if let action {
                Button(action: action) {
                    HStack(spacing: 4) { Text(value).font(MFont.subheadline).multilineTextAlignment(.leading); Image(systemName: "chevron.up.chevron.down").font(.caption2) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(MColor.accent)
                .accessibilityHint("Change")
            } else {
                Text(value).font(MFont.subheadline)
            }
            Spacer()
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
    }
}

/// Tap "December" → change it. Approximate options first; exact date optional.
struct WhenPickerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let memory: Memory
    @State private var date = Date.now

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                Text("When is this?").font(MFont.title).tracking(-0.3)
                VStack(spacing: MSpacing.s) {
                    quick("No date") { set(nil, nil, nil) }
                    quick("Tomorrow") { let d = Date.now.adding(days: 1); set(d, d, .day) }
                    quick("This weekend") { var c = DateComponents(); c.weekday = 7; if let d = Calendar.current.nextDate(after: .now, matching: c, matchingPolicy: .nextTime) { set(d, d.adding(days: 1), .week) } }
                    quick("Next week") { let d = Date.now.adding(days: 7); set(d, d.adding(days: 6), .week) }
                    quick("Next month") { if let d = Calendar.current.date(byAdding: .month, value: 1, to: .now), let i = Calendar.current.dateInterval(of: .month, for: d) { set(i.start, i.end.adding(days: -1), .month) } }
                }
                DatePicker("Exact date", selection: $date, displayedComponents: .date).datePickerStyle(.graphical)
                Button("Use this date") { set(Calendar.current.startOfDay(for: date), Calendar.current.startOfDay(for: date), .day) }.buttonStyle(PrimaryButtonStyle())
            }
            .padding(MSpacing.l)
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private func quick(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(label).font(MFont.body).foregroundStyle(MColor.textPrimary); Spacer() }
                .padding(MSpacing.m).frame(minHeight: MTouch.minimum)
                .background(MColor.surface, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
        }.buttonStyle(.plain)
    }

    private func set(_ start: Date?, _ end: Date?, _ precision: TemporalPrecision?) {
        memory.referencedDateStart = start; memory.referencedDateEnd = end; memory.referencedPrecision = precision
        for plan in memory.plans { plan.possibleDateStart = start; plan.possibleDateEnd = end; plan.possiblePrecision = precision }
        for promise in memory.promises { promise.dueDate = start }
        memory.metadata["userEdited"] = "true"
        memory.updatedAt = .now
        env.storage.save()
        dismiss()
    }
}

/// "No, that's not Sarah. That's Priya." Pick an existing person or type a new name.
struct PersonPickerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let memory: Memory
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Who is this about?") {
                    TextField("New name", text: $newName)
                        .onSubmit(applyNew)
                        .accessibilityIdentifier("personPickerNewName")
                    if !newName.isBlank { Button("Use “\(newName.trimmed)”", action: applyNew) }
                }
                Section("People you know") {
                    ForEach(env.storage.fetchPeople()) { p in
                        Button { apply(p.displayName) } label: {
                            HStack { PersonAvatar(name: p.displayName, size: 30); Text(p.displayName); Spacer()
                                if memory.people.contains(where: { $0.id == p.id }) { Image(systemName: "checkmark").foregroundStyle(MColor.accent) } }
                        }
                        .foregroundStyle(MColor.textPrimary)
                    }
                }
                if !memory.people.isEmpty {
                    Section {
                        Button("Nobody — remove person", role: .destructive) {
                            for p in memory.people { memory.people.removeAll { $0.id == p.id } }
                            memory.refreshCaches()
                            env.storage.save(); dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func applyNew() { apply(newName) }
    private func apply(_ name: String) {
        env.actions.correctPerson(in: memory, from: memory.people.first, to: name)
        env.toast("Got it — \(name.trimmed).")
        dismiss()
    }
}
