import SwiftUI

/// Notifications: who subscribed, who bought, who asked for something. Everything here is money or a
/// person waiting on you — there is no algorithmic noise to surface.
struct InboxView: View {
    @Environment(AppEnvironment.self) private var env
    var embedded = false

    private var pendingRequests: [Booking] {
        env.social.myBookings.filter { $0.creatorID == env.social.myID && ($0.status == .asked || $0.status == .requested) }
    }

    var body: some View {
        Group { if embedded { content } else { NavigationStack { content.socialDestinations() } } }
            .modifier(SocialErrorAlert())
    }

    private var content: some View {
        List {
            if !pendingRequests.isEmpty {
                Section("Waiting on you") {
                    ForEach(pendingRequests) { b in
                        NavigationLink(value: SocialRoute.bookings) {
                            row(name: b.buyerName, id: b.buyerID,
                                line: "\(b.buyerName) asked for \(b.kind.label.lowercased())",
                                detail: b.status == .asked ? "Name your price" : "Paid — confirm it",
                                at: b.createdAt)
                        }
                    }
                }
            }
            if !env.social.mySales.isEmpty {
                Section("Sales") {
                    ForEach(env.social.mySales.prefix(20)) { s in
                        row(name: s.buyerName, id: s.buyerID,
                            line: "\(s.buyerName) unlocked a post",
                            detail: (Double(s.amountMinor) / 100).formatted(.currency(code: s.currency).precision(.fractionLength(0))),
                            at: s.createdAt)
                    }
                }
            }
            if !env.social.subscribers.isEmpty {
                Section("Subscribers") {
                    ForEach(env.social.subscribers.prefix(20)) { sub in
                        row(name: sub.subscriberName, id: sub.subscriberID,
                            line: "\(sub.subscriberName) subscribed",
                            detail: sub.isActive ? "Until \(sub.expiresAt.formatted(date: .abbreviated, time: .omitted))" : "Lapsed",
                            at: sub.startedAt)
                    }
                }
            }
            if !env.social.tipsReceived.isEmpty {
                Section("Tips") {
                    ForEach(env.social.tipsReceived.prefix(20)) { t in
                        row(name: t.fromName, id: t.fromID,
                            line: "\(t.fromName) tipped \(t.amount.emoji)",
                            detail: t.note.isEmpty ? env.social.price(for: t.amount) : "“\(t.note)”",
                            at: t.createdAt)
                    }
                }
            }
            if pendingRequests.isEmpty && env.social.mySales.isEmpty && env.social.subscribers.isEmpty && env.social.tipsReceived.isEmpty {
                Text("Nothing yet. Subscriptions, unlocks, tips and requests land here.")
                    .font(MFont.subheadline).foregroundStyle(MColor.textSecondary).listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(MColor.background)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await env.social.refreshStorefront(); await env.social.refreshCreator() }
        .task { await env.social.refreshStorefront(); await env.social.refreshCreator(); await env.social.markActivityRead() }
    }

    private func row(name: String, id: String, line: String, detail: String, at: Date) -> some View {
        HStack(spacing: MSpacing.m) {
            AvatarView(userID: id, name: name, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(line).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary)
                Text(detail).font(MFont.caption).foregroundStyle(MColor.textSecondary).lineLimit(2)
            }
            Spacer()
            Text(at.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(MColor.textTertiary)
        }
        .padding(.vertical, 2)
    }
}
