import SwiftUI

struct PeopleView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var path = NavigationPath()
    @State private var people: [Person] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if people.isEmpty {
                    EmptyStateView(symbol: "person.2", title: "The people you remember will appear here.", message: "A name in a screenshot, a friend in a voice note — MOMENT builds this from what you capture. Nothing is imported from Contacts.")
                } else {
                    List(people) { p in
                        NavigationLink(value: Route.person(p.id)) { PersonCard(person: p) }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("People")
            .background(AmbientBackdrop(intensity: 0.4).ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .momentDestinations()
            .withCaptureButton()
            .task { reload() }
            .onChange(of: env.surface.changeToken) { _, _ in reload() }
        }
    }

    private func reload() {
        people = env.storage.fetchPeople()
            .filter { !$0.visibleMemories.isEmpty || !$0.pendingPromises.isEmpty || !$0.openGiftIdeas.isEmpty }
            .sorted { ($0.lastInteractionAt ?? .distantPast) > ($1.lastInteractionAt ?? .distantPast) }
    }
}

struct PersonCard: View {
    let person: Person
    var body: some View {
        HStack(spacing: MSpacing.m) {
            PersonAvatar(name: person.displayName, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(person.displayName).font(MFont.headline)
                    if let r = person.statedRelationship { Text(r).font(MFont.caption).foregroundStyle(MColor.textSecondary) }
                }
                if let last = person.lastInteractionAt { Text("Last seen \(last.relativeDescription.lowercased())").font(MFont.caption).foregroundStyle(MColor.textTertiary) }
                HStack(spacing: 8) {
                    let pending = person.pendingPromises.count
                    if pending > 0 { TagChip(text: "\(pending) pending promise\(pending == 1 ? "" : "s")", symbol: "hand.raised") }
                    let plans = person.activePlans.count
                    if plans > 0 { TagChip(text: "\(plans) plan\(plans == 1 ? "" : "s")", symbol: "map") }
                    let gifts = person.openGiftIdeas.count
                    if gifts > 0 { TagChip(text: "\(gifts) gift idea\(gifts == 1 ? "" : "s")", symbol: "gift") }
                    let memories = person.visibleMemories.count
                    if pending == 0 && plans == 0 && gifts == 0 { TagChip(text: "\(memories) memor\(memories == 1 ? "y" : "ies")") }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
