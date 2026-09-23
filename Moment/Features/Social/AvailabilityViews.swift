import SwiftUI

/// The creator's hours. The whole point is that this is the only place they ever say when they're free —
/// buyers pick from what it produces, so there's no second calendar to keep in step.
struct AvailabilityEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var a = CreatorAvailability()
    @State private var loaded = false
    @State private var adding = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Taking bookings", isOn: $a.acceptingBookings).accessibilityIdentifier("acceptingBookings")
                    Text(a.acceptingBookings
                         ? "People can book the call offers you've priced, inside these hours."
                         : "Your hours are kept. Nobody can book a new call until you switch this back on.")
                        .font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                }

                Section("Your hours") {
                    if a.windows.isEmpty {
                        Text("No hours yet. Add one — say Thursday evening — and calls can only ever land inside it.")
                            .font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                    }
                    ForEach(a.windows.sorted(by: windowOrder)) { w in
                        HStack {
                            Text(w.label())
                            Spacer()
                            Button(role: .destructive) { a.windows.removeAll { $0.id == w.id } } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(MColor.danger)
                                .accessibilityLabel("Remove \(w.label())")
                        }
                        .accessibilityIdentifier("window-\(w.id)")
                    }
                    Button { adding = true } label: { Label("Add hours", systemImage: "plus") }
                        .accessibilityIdentifier("addWindow")
                }

                Section("Times are yours") {
                    Picker("Time zone", selection: $a.timeZoneID) {
                        ForEach(Self.zones, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                    }
                    Text("A buyer in another country sees these hours converted to theirs. You never do the maths.")
                        .font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                }

                Section("Rules") {
                    Stepper("At least \(a.minNoticeHours)h notice", value: $a.minNoticeHours, in: 0...168, step: 1)
                    Stepper("Book up to \(a.maxDaysAhead) days ahead", value: $a.maxDaysAhead, in: 1...90)
                    Stepper("\(a.bufferMinutes) min gap between calls", value: $a.bufferMinutes, in: 0...60, step: 5)
                }

                Section {
                    Text(preview)
                        .font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                        .accessibilityIdentifier("availabilityPreview")
                }
            }
            .navigationTitle("When you're free")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await env.social.saveAvailability(a); Haptics.completed(); dismiss() } }
                        .accessibilityIdentifier("saveAvailability")
                }
            }
            .sheet(isPresented: $adding) { AddWindowSheet { a.windows.append($0) } }
            .task {
                guard !loaded else { return }
                await env.social.loadAvailability(env.social.myID)
                a = env.social.myAvailability
                loaded = true
            }
        }
    }

    /// What the rules add up to, said back to them in plain language.
    private var preview: String {
        guard a.acceptingBookings, !a.windows.isEmpty else { return "Nobody can book a call right now." }
        let count = CallSlots.slots(availability: a, minutes: 15, limit: 40).count
        if count == 0 { return "These rules leave no slots in the next \(a.maxDaysAhead) days — usually the notice period is longer than the window." }
        return "That's \(count == 40 ? "40+" : "\(count)") fifteen-minute slots in the next \(a.maxDaysAhead) days."
    }

    private func windowOrder(_ l: CreatorAvailability.Window, _ r: CreatorAvailability.Window) -> Bool {
        l.weekday == r.weekday ? l.startMinute < r.startMinute : l.weekday < r.weekday
    }

    /// A short list rather than every zone on earth: the ones a creator actually picks.
    static let zones: [String] = {
        let common = ["Asia/Kolkata", "Asia/Dubai", "Asia/Singapore", "Asia/Tokyo", "Europe/London", "Europe/Berlin",
                      "America/New_York", "America/Chicago", "America/Los_Angeles", "Australia/Sydney", "UTC"]
        let mine = TimeZone.current.identifier
        return common.contains(mine) ? common : [mine] + common
    }()
}

/// One window: a day and a from–to.
struct AddWindowSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (CreatorAvailability.Window) -> Void
    @State private var weekday = Calendar.current.component(.weekday, from: .now)
    @State private var start = 18 * 60
    @State private var end = 21 * 60

    /// Every half hour of the day, which is as fine as anyone sets office hours.
    static let halfHours: [Int] = stride(from: 0, through: 23 * 60 + 30, by: 30).map { $0 }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Day", selection: $weekday) {
                    ForEach(1...7, id: \.self) { Text(CreatorAvailability.Window.dayName($0)).tag($0) }
                }
                Picker("From", selection: $start) {
                    ForEach(Self.halfHours, id: \.self) { Text(CreatorAvailability.Window.clock($0)).tag($0) }
                }
                Picker("To", selection: $end) {
                    ForEach(Self.halfHours.filter { $0 > start }, id: \.self) { Text(CreatorAvailability.Window.clock($0)).tag($0) }
                }
            }
            .navigationTitle("Add hours").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(CreatorAvailability.Window(weekday: weekday, startMinute: start, endMinute: max(end, start + 30)))
                        dismiss()
                    }
                    .accessibilityIdentifier("confirmWindow")
                }
            }
            .onChange(of: start) { _, s in if end <= s { end = min(24 * 60, s + 60) } }
        }
        .presentationDetents([.medium])
    }
}

/// Picking a time from what the creator actually offers, in the buyer's own time zone.
/// A slot that isn't here can't be booked — there is no free-text "how about 3am?".
struct SlotPicker: View {
    let slots: [Date]
    let creatorZone: TimeZone
    @Binding var selection: Date?

    private var days: [(day: Date, slots: [Date])] { CallSlots.byDay(slots, timeZone: .current) }

    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            if slots.isEmpty {
                Text("No times open right now. Their hours may be full, or booked out.")
                    .font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                    .accessibilityIdentifier("noSlots")
            }
            ForEach(days.prefix(7), id: \.day) { group in
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text(group.day.formatted(.dateTime.weekday(.wide).day().month()))
                        .font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: MSpacing.s)], spacing: MSpacing.s) {
                        ForEach(group.slots, id: \.self) { slot in
                            Button { selection = slot } label: {
                                Text(slot.formatted(.dateTime.hour().minute()))
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(selection == slot ? .white : MColor.textPrimary)
                            .background(selection == slot ? AnyShapeStyle(MColor.accent) : AnyShapeStyle(.ultraThinMaterial),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityIdentifier("slot-\(Int(slot.timeIntervalSince1970))")
                        }
                    }
                }
            }
            if creatorZone.identifier != TimeZone.current.identifier, !slots.isEmpty {
                Text("Shown in your time. They're on \(creatorZone.identifier.replacingOccurrences(of: "_", with: " ")).")
                    .font(MFont.caption).foregroundStyle(MColor.textTertiary)
            }
        }
    }
}

/// Every call the two of you still owe each other, on either side of the money.
struct UpcomingCallsCard: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        let calls = env.social.upcomingCalls
        if !calls.isEmpty {
            VStack(alignment: .leading, spacing: MSpacing.s) {
                Text("CALLS").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                ForEach(calls.prefix(3)) { b in
                    NavigationLink(value: SocialRoute.call(b.id)) {
                        HStack(spacing: MSpacing.m) {
                            Image(systemName: b.kind.symbol).font(.headline).foregroundStyle(MColor.accent).frame(width: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(b.creatorID == env.social.myID ? b.buyerName : b.creatorName).font(.subheadline.weight(.semibold))
                                Text("\(b.startsAt.formatted(.relative(presentation: .named))) · \(b.paidMinutes) min").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                            }
                            Spacer()
                            if b.joinWindow().contains(.now) {
                                Text("Join").font(.caption.weight(.bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 5).background(MColor.accent, in: Capsule())
                            } else {
                                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(MColor.textTertiary)
                            }
                        }
                        .padding(MSpacing.m)
                    }
                    .buttonStyle(.plain).glass(radius: 16)
                    .accessibilityIdentifier("upcomingCall-\(b.id)")
                }
            }
        }
    }
}
