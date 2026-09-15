import SwiftUI

/// Smart cleanup suggestions. The user decides; nothing is deleted silently.
struct InsightsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var insights: [Insight] = []

    var body: some View {
        List {
            if insights.isEmpty { Text("Nothing to tidy up.").foregroundStyle(MColor.textSecondary) }
            ForEach(insights) { insight in
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text(insight.kind == "duplicate" ? "I think these are the same Moment." : insight.title).font(MFont.headline)
                    Text(insight.body).font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                    HStack(spacing: MSpacing.s) {
                        switch insight.kind {
                        case "duplicate":
                            Button("Merge") { merge(insight) }.buttonStyle(ChipButtonStyle(prominent: true))
                            Button("Keep separate") { dismiss(insight) }.buttonStyle(ChipButtonStyle())
                        case "samePerson":
                            Button("Merge") { mergePeople(insight) }.buttonStyle(ChipButtonStyle(prominent: true))
                            Button("Keep separate") { dismiss(insight) }.buttonStyle(ChipButtonStyle())
                        case "stalePlan":
                            Button("It happened") { resolvePlan(insight, .completed) }.buttonStyle(ChipButtonStyle(prominent: true))
                            Button("Let it go") { resolvePlan(insight, .cancelled) }.buttonStyle(ChipButtonStyle())
                            Button("Keep") { dismiss(insight) }.buttonStyle(ChipButtonStyle())
                        default:
                            Button("Ignore") { dismiss(insight) }.buttonStyle(ChipButtonStyle())
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AmbientBackdrop(intensity: 0.4).ignoresSafeArea())
        .navigationTitle("Tidy up")
        .task { await generate() }
    }

    private func generate() async {
        env.surface.generateInsights()
        insights = env.storage.fetchInsights()
        env.analytics.track(.insightOpened)
    }

    private func dismiss(_ i: Insight) { i.dismissedAt = .now; env.storage.save(); insights = env.storage.fetchInsights() }
    private func merge(_ i: Insight) {
        let memories = i.memoryIDs.compactMap { env.storage.memory(id: $0) }
        _ = env.actions.merge(memories)
        i.resolvedAt = .now; env.storage.save(); insights = env.storage.fetchInsights(); env.toast("Merged. Both sources kept.")
    }
    private func mergePeople(_ i: Insight) {
        guard i.personIDs.count == 2, let a = env.storage.person(id: i.personIDs[0]), let b = env.storage.person(id: i.personIDs[1]) else { dismiss(i); return }
        let (canonical, dup) = a.memories.count >= b.memories.count ? (a, b) : (b, a)
        env.actions.merge(person: dup, into: canonical)
        i.resolvedAt = .now; env.storage.save(); insights = env.storage.fetchInsights()
    }
    private func resolvePlan(_ i: Insight, _ status: PlanStatus) {
        for m in i.memoryIDs.compactMap({ env.storage.memory(id: $0) }) { for p in m.plans { env.actions.setStatus(p, status) } }
        i.resolvedAt = .now; env.storage.save(); insights = env.storage.fetchInsights()
    }
}
