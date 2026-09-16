import SwiftUI

/// Discover: public Moments by place, search, and people. Never a "for you" trap — you look for
/// something, you find it.
struct DiscoverView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""
    @State private var place: String?
    @State private var results: [SocialMoment] = []
    @State private var people: [SocialUser] = []
    @State private var loading = false

    private var places: [String] {
        Array(Set(results.compactMap(\.coarsePlace).filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MSpacing.l) {
                    if !people.isEmpty {
                        Text("PEOPLE").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                        ForEach(people) { u in
                            NavigationLink(value: SocialRoute.profile(u.id)) {
                                HStack(spacing: MSpacing.m) { PersonAvatar(name: u.displayName, size: 40); VStack(alignment: .leading) { Text(u.displayName).font(MFont.headline).foregroundStyle(MColor.textPrimary); Text("@\(u.handle)").font(MFont.caption).foregroundStyle(MColor.textSecondary) }; Spacer(); if u.isPrivateAccount { Image(systemName: "lock").foregroundStyle(MColor.textTertiary) } }
                                    .momentCard(padding: MSpacing.m)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("discoverUser-\(u.handle)")
                        }
                    }
                    if !places.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: MSpacing.s) {
                                Button("Everywhere") { place = nil }.buttonStyle(ChipButtonStyle(prominent: place == nil))
                                ForEach(places, id: \.self) { p in Button(p) { place = p }.buttonStyle(ChipButtonStyle(prominent: place == p)).accessibilityIdentifier("place-\(p)") }
                            }
                        }
                    }
                    let shown = results.filter { place == nil || $0.coarsePlace == place }
                    if shown.isEmpty && !loading {
                        EmptyStateView(symbol: "safari", title: query.isEmpty ? "Nothing public nearby yet" : "No Moments for \"\(query)\"", message: "Public Moments from people and places show up here. Make one public to be found.")
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: MSpacing.s), GridItem(.flexible(), spacing: MSpacing.s)], spacing: MSpacing.s) {
                        ForEach(shown) { m in
                            NavigationLink(value: SocialRoute.moment(m.id)) { MomentTile(moment: m) }.buttonStyle(PressScaleStyle())
                        }
                    }
                }
                .padding(MSpacing.l)
                .padding(.bottom, 80)
            }
            .background(MColor.background)
            .navigationTitle("Discover")
            .searchable(text: $query, prompt: "Places, Moments, @people")
            .task(id: query) { await search() }
            .refreshable { await search() }
            .socialDestinations()
        }
    }

    private func search() async {
        loading = true; defer { loading = false }
        async let m = env.social.discover(query: query.isBlank ? nil : query, place: nil)
        async let p = query.isBlank ? [] : env.social.search(people: query)
        results = await m; people = await p
    }
}
