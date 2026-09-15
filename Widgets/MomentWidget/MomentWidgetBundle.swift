import WidgetKit
import SwiftUI

@main
struct MomentWidgetBundle: WidgetBundle {
    var body: some Widget {
        MomentWidget()
        FollowUpsWidget()
        TodayWidget()
        LockScreenWidget()
    }
}

struct MomentEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

/// Reads the snapshot the app wrote. No SwiftData in the widget process, no heavy work.
struct MomentProvider: TimelineProvider {
    func placeholder(in context: Context) -> MomentEntry { MomentEntry(date: .now, snapshot: .placeholder) }
    func getSnapshot(in context: Context, completion: @escaping (MomentEntry) -> Void) { completion(MomentEntry(date: .now, snapshot: WidgetSnapshot.load() ?? (context.isPreview ? .placeholder : nil))) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MomentEntry>) -> Void) {
        let entry = MomentEntry(date: .now, snapshot: WidgetSnapshot.load())
        // Refresh a few times a day; the app also reloads timelines when the feed changes.
        let next = Calendar.current.date(byAdding: .hour, value: 4, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

extension WidgetSnapshot {
    static let placeholder = WidgetSnapshot(items: [Item(id: UUID(), category: "Upcoming", headline: "Sarah's birthday is in 9 days.", detail: "You have one gift idea saved.", deepLink: "moment://inbox")], pendingFollowUps: 2, todayCount: 3, lockScreenAllowed: false)
}

// MARK: - Widget 1: What's worth remembering?

struct MomentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppGroup.widgetKind, provider: MomentProvider()) { entry in
            MomentWidgetView(entry: entry).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("MOMENT")
        .description("What's worth remembering right now.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct MomentWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MomentEntry
    var body: some View {
        let items = entry.snapshot?.items ?? []
        VStack(alignment: .leading, spacing: 6) {
            Text("MOMENT").font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
            if let first = items.first {
                Text(first.category.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                Text(first.headline).font(family == .systemSmall ? .subheadline.weight(.semibold) : .headline).lineLimit(family == .systemSmall ? 3 : 2)
                if family != .systemSmall, let d = first.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if family == .systemMedium, items.count > 1 {
                    Divider()
                    ForEach(items.dropFirst().prefix(2)) { item in
                        Text("\(item.category): \(item.headline)").font(.caption).lineLimit(1)
                    }
                }
                if family == .systemLarge {
                    Divider().padding(.vertical, 4)
                    ForEach(items.dropFirst().prefix(4)) { item in
                        Link(destination: URL(string: item.deepLink) ?? URL(string: "moment://home")!) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.category.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                                Text(item.headline).font(.subheadline).lineLimit(2)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Label("\(entry.snapshot?.pendingFollowUps ?? 0) follow-ups", systemImage: "hand.raised").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Label("\(entry.snapshot?.todayCount ?? 0) today", systemImage: "sun.max").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("What's worth remembering?").font(.subheadline.weight(.semibold))
                Text("Nothing needs you right now.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: items.first?.deepLink ?? "moment://home"))
    }
}

// MARK: - Widget 2: Follow ups

struct FollowUpsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppGroup.followUpsWidgetKind, provider: MomentProvider()) { entry in
            let n = entry.snapshot?.pendingFollowUps ?? 0
            VStack(alignment: .leading, spacing: 6) {
                Text("FOLLOW UPS").font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                Text("\(n)").font(.system(size: 40, weight: .bold, design: .rounded))
                Text(n == 1 ? "pending" : "pending").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.background, for: .widget)
            .widgetURL(URL(string: "moment://home"))
        }
        .configurationDisplayName("Follow ups")
        .description("Promises waiting on someone.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Widget 3: Today

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppGroup.todayWidgetKind, provider: MomentProvider()) { entry in
            let n = entry.snapshot?.todayCount ?? 0
            VStack(alignment: .leading, spacing: 6) {
                Text("TODAY").font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                Text("\(n)").font(.system(size: 40, weight: .bold, design: .rounded))
                Text(n == 1 ? "thing worth remembering" : "things worth remembering").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.background, for: .widget)
            .widgetURL(URL(string: "moment://home"))
        }
        .configurationDisplayName("Today")
        .description("How many things deserve your attention today.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Lock Screen: minimal, opt-in content

struct LockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppGroup.lockScreenWidgetKind, provider: MomentProvider()) { entry in
            LockScreenView(entry: entry).containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("MOMENT")
        .description("Pending follow-ups. Shows details only if you allow it in Settings.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct LockScreenView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MomentEntry
    var body: some View {
        let snap = entry.snapshot
        let n = snap?.pendingFollowUps ?? 0
        switch family {
        case .accessoryCircular:
            VStack(spacing: 0) { Image(systemName: "hand.raised").font(.caption); Text("\(n)").font(.headline) }
        case .accessoryInline:
            Text(snap?.lockScreenAllowed == true ? (snap?.items.first?.headline ?? "\(n) follow-ups") : "\(n) follow-up\(n == 1 ? "" : "s")")
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text("MOMENT").font(.caption2.weight(.bold))
                if snap?.lockScreenAllowed == true, let first = snap?.items.first {
                    Text(first.headline).font(.caption).lineLimit(2)
                } else {
                    Text("\(n) pending follow-up\(n == 1 ? "" : "s")").font(.caption)
                }
            }
        }
    }
}
