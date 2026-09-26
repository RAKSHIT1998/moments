import SwiftUI

/// Finding a creator you don't already follow.
///
/// The app had no way to do this at all: the feed shows people you follow or pay, and the only search
/// anywhere was inside "New message" for picking someone to DM. So a creator who wasn't already in your
/// feed was unreachable from inside the app — which on a platform whose whole business is people
/// finding creators is the wrong shape.
///
/// A grid rather than a list, because what a creator looks like is most of the decision, and the price
/// is on every card: nobody should have to tap through to find out what someone costs.
struct DiscoverView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""
    @State private var results: [SocialUser] = []
    @State private var searching = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: MSpacing.s)]

    /// Everyone this phone knows about, or the ones matching what's typed. The backend's own user
    /// search is the source — the same list "New message" uses — so there is one idea of who exists.
    private var creators: [SocialUser] {
        let q = query.trimmed.lowercased().replacingOccurrences(of: "@", with: "")
        return results
            .filter { $0.id != env.social.myID && !env.social.blocked.contains($0.id) }
            .filter { q.isEmpty || $0.displayName.lowercased().contains(q) || $0.handle.lowercased().contains(q) }
            .sorted { env.social.sets(of: $0.id).count > env.social.sets(of: $1.id).count }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: MSpacing.s) {
                ForEach(creators) { u in card(u) }
            }
            .padding(.horizontal, MSpacing.page)
            .padding(.top, MSpacing.s)
            .padding(.bottom, 90)

            if creators.isEmpty {
                VStack(spacing: MSpacing.s) {
                    Text(query.isBlank ? "Nobody yet." : "Nobody by that name.").font(MFont.title)
                    Text(query.isBlank
                         ? "Creators show up here as their posts reach this phone."
                         : "Handles are exact; try part of a display name instead.")
                        .font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(MSpacing.xl)
                .accessibilityIdentifier("discoverEmpty")
            }
        }
        .background(LiquidBackdrop())
        // `.always`, not the default: a search field that hides until you pull down is a search field
        // most people never find, and finding someone is the entire point of this screen.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search name or @handle")
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .accessibilityIdentifier("discoverGrid")
    }

    private func load() async {
        searching = true
        results = await env.social.search(people: "")
        // Their covers and prices come from the storefront, which isn't in the user record.
        for u in results where env.social.sets(of: u.id).isEmpty {
            await env.social.loadStorefront(u.id)
            await env.social.loadCreatorPlan(u.id)
        }
        searching = false
    }

    /// Cover, avatar on its edge, name, handle, and what they cost.
    private func card(_ u: SocialUser) -> some View {
        let sets = env.social.sets(of: u.id).filter(\.visible)
        let plan = env.social.plan(for: u.id)
        let free = sets.filter(\.isFree).count
        return NavigationLink(value: SocialRoute.profile(u.id)) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    Color.clear
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            if let cover = sets.first(where: { $0.isFree })?.cover ?? sets.first?.cover {
                                SocialImage(ref: cover).aspectRatio(contentMode: .fill)
                            } else {
                                LinearGradient(colors: [MColor.accent.opacity(0.55), MColor.accent.opacity(0.12)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            }
                        }
                        .clipped()
                    AvatarView(userID: u.id, name: u.displayName, size: 36)
                        .overlay(Circle().strokeBorder(MColor.surface, lineWidth: 2))
                        .padding(.leading, MSpacing.s)
                        .offset(y: 16)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(u.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(MColor.textPrimary)
                    if !u.handle.isEmpty {
                        Text("@\(u.handle)").font(MFont.caption).foregroundStyle(MColor.textSecondary).lineLimit(1)
                    }
                    Text(priceLine(plan: plan, sets: sets.count, free: free))
                        .font(.caption.weight(.semibold)).foregroundStyle(MColor.accent)
                        .padding(.top, 3)
                }
                .padding(.horizontal, MSpacing.s)
                .padding(.top, 22)
                .padding(.bottom, MSpacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(MColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(MColor.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("discoverCreator-\(u.id)")
        .accessibilityElement(children: .combine)
    }

    /// What they cost, said the most useful way round: a subscription price if they have one, else how
    /// much of their work is free — which is what decides whether a stranger taps.
    private func priceLine(plan: CreatorPlan?, sets: Int, free: Int) -> String {
        if let plan { return "\(plan.priceLabel()) / 30 days" }
        if free > 0 { return "\(free) free" }
        return sets == 1 ? "1 post" : "\(sets) posts"
    }
}
