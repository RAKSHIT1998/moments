import SwiftUI
import CoreLocation

/// Nearby: the places around you — who's there, what's happening, what people added.
/// Your own coordinate is used once to ask "within 3 km?" and is never uploaded.
struct NearbyView: View {
    @Environment(AppEnvironment.self) private var env
    var embedded = false
    @State private var here: CLLocationCoordinate2D?
    @State private var loading = false
    @State private var asked = false

    var body: some View {
        Group { if embedded { content } else { NavigationStack { content.socialDestinations() } } }
            .modifier(SocialErrorAlert())
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MSpacing.xl) {
                if env.location.isDenied {
                    permissionCard(denied: true)
                } else if here == nil && !loading {
                    permissionCard(denied: false)
                } else {
                    if let here {
                        let places = env.social.nearbyPlaces(latitude: here.latitude, longitude: here.longitude)
                        if loading && places.isEmpty { SkeletonFeedCard().padding(.horizontal, MSpacing.m) }
                        if !loading && places.isEmpty {
                            VStack(alignment: .leading, spacing: MSpacing.s) {
                                Text("Quiet around here").font(MFont.title)
                                Text("No public Moments within \(Int(env.social.nearbyRadiusKm)) km yet. Be the first — add the place to your next one.").font(MFont.body).foregroundStyle(MColor.textSecondary)
                            }
                            .padding(.horizontal, MSpacing.m)
                        }
                        if !env.social.nearbyNow.isEmpty {
                            VStack(alignment: .leading, spacing: MSpacing.s) {
                                Text("Here now").sectionLabel().padding(.horizontal, MSpacing.m)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: MSpacing.l) {
                                        ForEach(env.social.nearbyNow) { n in
                                            NavigationLink(value: SocialRoute.profile(n.authorID)) {
                                                VStack(spacing: 4) {
                                                    AvatarView(userID: n.authorID, name: n.authorName, size: 56).overlay(alignment: .bottomTrailing) { if n.isStatus { Text(n.activity.emoji).font(.caption).padding(3).background(MColor.background, in: Circle()) } }
                                                    Text(n.authorName.split(separator: " ").first.map(String.init) ?? "").font(MFont.caption).foregroundStyle(MColor.textPrimary)
                                                    Text(n.place?.name ?? n.coarsePlace ?? "").font(.caption2).foregroundStyle(MColor.textTertiary).lineLimit(1)
                                                }.frame(width: 80)
                                            }.buttonStyle(.plain)
                                        }
                                    }.padding(.horizontal, MSpacing.m)
                                }
                            }
                        }
                        if !places.isEmpty {
                            VStack(alignment: .leading, spacing: MSpacing.s) {
                                Text("Places near you").sectionLabel().padding(.horizontal, MSpacing.m)
                                ForEach(places, id: \.place.id) { p in
                                    NavigationLink(value: SocialRoute.place(p.place)) { PlaceRow(place: p.place, moments: p.moments, people: p.people, live: p.live, km: p.km) }.buttonStyle(.plain)
                                }
                            }
                        }
                        if !env.social.nearbyMoments.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Around you").sectionLabel().padding(.horizontal, MSpacing.m).padding(.bottom, MSpacing.s)
                                ForEach(env.social.nearbyMoments) { MomentPostCard(moment: $0) }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, MSpacing.m).padding(.bottom, 80)
        }
        .background(MColor.background)
        .navigationTitle("Nearby")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink(value: SocialRoute.nearbyMap) { Image(systemName: "map") }.accessibilityLabel("Map").accessibilityIdentifier("nearbyMapLink") } }
        .refreshable { await load() }
        .task { if !asked { asked = true; await load() } }
        .accessibilityIdentifier("nearbyScreen")
    }

    private func permissionCard(denied: Bool) -> some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            Image(systemName: "location").font(.title2.weight(.light))
            Text(denied ? "Location is off" : "See what's happening around you").font(MFont.title)
            Text(denied ? "Turn on location for MOMENT in Settings to see nearby places and Moments. Your location is only used on your phone to ask what's close." : "Cafés, beaches, venues — and the Moments people made there. Your location stays on your phone; only \"within \(Int(env.social.nearbyRadiusKm)) km\" is asked.").font(MFont.body).foregroundStyle(MColor.textSecondary)
            if denied { Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!).buttonStyle(PrimaryButtonStyle()) }
            else { Button { Task { await load() } } label: { Text("Show nearby").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("enableNearby") }
        }
        .padding(MSpacing.l)
    }

    private func load() async {
        loading = true; defer { loading = false }
        here = await env.location.locate()
        if let here { await env.social.refreshNearby(latitude: here.latitude, longitude: here.longitude) }
    }
}

struct PlaceRow: View {
    let place: SocialPlace
    let moments: Int
    let people: Int
    let live: Bool
    let km: Double
    var body: some View {
        HStack(spacing: MSpacing.m) {
            Image(systemName: symbol).font(.title3.weight(.light)).frame(width: 44, height: 44).background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(place.name).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary).lineLimit(1)
                    if live { Text("Live").font(MFont.caption.weight(.semibold)).foregroundStyle(MColor.danger) }
                }
                Text("\(place.area.isEmpty ? "" : place.area + " · ")\(moments) \(moments == 1 ? "Moment" : "Moments") · \(people) people").font(MFont.caption).foregroundStyle(MColor.textSecondary).lineLimit(1)
            }
            Spacer()
            Text(km < 1 ? "\(Int(km * 1000)) m" : String(format: "%.1f km", km)).font(MFont.caption).foregroundStyle(MColor.textTertiary)
        }
        .padding(.horizontal, MSpacing.m).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("place-\(place.id)")
    }
    private var symbol: String {
        let c = (place.category ?? "").lowercased()
        if c.contains("cafe") || c.contains("coffee") { return "cup.and.saucer" }
        if c.contains("restaurant") || c.contains("food") { return "fork.knife" }
        if c.contains("bar") || c.contains("club") || c.contains("night") { return "wineglass" }
        if c.contains("beach") { return "beach.umbrella" }
        return "mappin.and.ellipse"
    }
}

/// A place page: everything that happened here, who's here now, and the way in — add yours.
struct PlaceView: View {
    @Environment(AppEnvironment.self) private var env
    let place: SocialPlace
    @State private var showNew = false
    @State private var showStart = false
    @State private var showNow = false

    private var moments: [SocialMoment] { env.social.placeMoments[place.id] ?? [] }
    private var live: [SocialMoment] { moments.filter(\.isLive) }
    private var hereNow: [NowPost] { env.social.nearbyNow.filter { $0.place?.id == place.id } }
    private var photos: [SocialMoment] { moments.filter { $0.coverRef != nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name).displayStyle()
                    Text([place.category, place.area.isEmpty ? nil : place.area].compactMap { $0 }.joined(separator: " · ")).font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                    Text("\(moments.count) \(moments.count == 1 ? "Moment" : "Moments") · \(Set(moments.flatMap(\.memberIDs)).count) people").font(MFont.caption).foregroundStyle(MColor.textTertiary)
                }
                HStack(spacing: MSpacing.s) {
                    Button { showNew = true } label: { Label("Add photos here", systemImage: "plus.square.on.square").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("placeAddPhotos")
                    Button { showNow = true } label: { Image(systemName: "bolt").frame(width: 48) }.buttonStyle(SecondaryButtonStyle()).accessibilityLabel("I'm here now")
                    Button { showStart = true } label: { Image(systemName: "qrcode").frame(width: 48) }.buttonStyle(SecondaryButtonStyle()).accessibilityLabel("Start an event here")
                }
                if !live.isEmpty {
                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        Text("Happening here").sectionLabel()
                        ForEach(live) { m in
                            HStack(spacing: MSpacing.m) {
                                SocialImage(ref: m.coverRef).frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) { Text(m.title).font(.subheadline.weight(.semibold)); Text("\(m.memberIDs.count) in · by \(m.creatorName)").font(MFont.caption).foregroundStyle(MColor.textSecondary) }
                                Spacer()
                                if m.memberIDs.contains(env.social.myID) { NavigationLink(value: SocialRoute.addSide(m.id)) { Text("Add") }.buttonStyle(ChipButtonStyle(prominent: true)) }
                                else { Button("Join") { Task { if await env.social.join(momentID: m.id) { env.toast("You're in."); await env.social.loadPlace(place.id) } } }.buttonStyle(ChipButtonStyle(prominent: true)) }
                            }
                        }
                    }
                }
                if !hereNow.isEmpty {
                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        Text("Here now").sectionLabel()
                        ForEach(hereNow) { NowStatusRow(post: $0) }
                    }
                }
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("Photos").sectionLabel()
                    if photos.isEmpty { Text("No photos here yet. Yours would be the first.").font(MFont.footnote).foregroundStyle(MColor.textSecondary) }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(photos) { m in
                            NavigationLink(value: SocialRoute.moment(m.id)) { SocialImage(ref: m.coverRef).aspectRatio(1, contentMode: .fill).clipped() }.buttonStyle(.plain).accessibilityLabel(m.title)
                        }
                    }
                    .padding(.horizontal, -MSpacing.m)
                }
                if !moments.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Moments here").sectionLabel().padding(.bottom, MSpacing.s)
                        ForEach(moments) { MomentPostCard(moment: $0).padding(.horizontal, -MSpacing.m) }
                    }
                }
            }
            .padding(MSpacing.m).padding(.bottom, 80)
        }
        .background(MColor.background)
        .navigationTitle(place.name).navigationBarTitleDisplayMode(.inline)
        .task { await env.social.loadPlace(place.id) }
        .refreshable { await env.social.loadPlace(place.id) }
        .sheet(isPresented: $showNew) { NavigationStack { NewMomentView(initial: prefilled) { m in showNew = false; env.social.pendingMomentID = m.id }.socialDestinations() } }
        .sheet(isPresented: $showStart) { NavigationStack { StartActivityBody(venue: place) } }
        .sheet(isPresented: $showNow) { NavigationStack { AnyoneUpComposerBody(venue: place) } }
        .accessibilityIdentifier("placeView")
    }

    private var prefilled: SocialService.NewMomentInput {
        var i = SocialService.NewMomentInput(title: "", visibility: .publicAll)
        i.place = place
        return i
    }
}

/// Pick the venue: search Apple Maps near you, or type your own.
struct PlacePickerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Binding var selected: SocialPlace?
    @State private var query = ""
    @State private var results: [SocialPlace] = []
    @State private var here: CLLocationCoordinate2D?

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty { Text(query.isEmpty ? "Cafés, bars, beaches, venues near you." : "Nothing found. Try the street or area.").foregroundStyle(MColor.textSecondary) }
                ForEach(results) { p in
                    Button { selected = p; Haptics.selection(); dismiss() } label: {
                        HStack(spacing: MSpacing.m) {
                            Image(systemName: "mappin.and.ellipse").foregroundStyle(MColor.textSecondary)
                            VStack(alignment: .leading, spacing: 2) { Text(p.name).foregroundStyle(MColor.textPrimary); Text(p.area).font(MFont.caption).foregroundStyle(MColor.textSecondary) }
                            Spacer()
                            if let here { Text(String(format: "%.1f km", p.distance(fromLatitude: here.latitude, longitude: here.longitude))).font(MFont.caption).foregroundStyle(MColor.textTertiary) }
                        }
                    }
                    .accessibilityIdentifier("pickPlace-\(p.id)")
                }
                if !query.isBlank {
                    Button { selected = SocialPlace(id: SocialPlace.makeID(name: query, latitude: here?.latitude ?? 0, longitude: here?.longitude ?? 0), name: query.trimmed, area: "", latitude: here?.latitude ?? 0, longitude: here?.longitude ?? 0, category: nil); dismiss() } label: { Label("Use \"\(query.trimmed)\"", systemImage: "plus") }
                }
            }
            .searchable(text: $query, prompt: "Search places")
            .task { here = await env.location.locate(); results = await PlaceSearch.search(query, near: here) }
            .task(id: query) { try? await Task.sleep(for: .milliseconds(350)); results = await PlaceSearch.search(query, near: here) }
            .navigationTitle("Where?").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
