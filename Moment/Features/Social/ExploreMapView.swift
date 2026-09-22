import SwiftUI
import MapKit
import CoreLocation

/// Search is a globe. Zoomed out you see where things are happening in the world; zoom in and
/// venues appear with what people added there. Tap a cluster to dive, a pin to open the place.
/// Only public Moments and opted-in NOW posts are on the map — and only their venues.
struct ExploreMapView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var position: MapCameraPosition = .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: 20, longitude: 40), distance: 30_000_000, heading: 0, pitch: 0))
    @State private var region: MKCoordinateRegion?
    @State private var query = ""
    @State private var people: [SocialUser] = []
    @State private var selectedPlace: SocialPlace?
    @State private var showList = false
    @State private var loading = false
    @State private var refreshTask: Task<Void, Never>?

    struct Cluster: Identifiable { let id: String; let coordinate: CLLocationCoordinate2D; let places: [SocialPlace]; let moments: Int; let live: Bool }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position) {
                UserAnnotation()
                ForEach(clusters) { c in
                    Annotation(c.places.count == 1 ? c.places[0].name : "", coordinate: c.coordinate, anchor: .center) {
                        Button {
                            if c.places.count == 1 { selectedPlace = c.places[0] } else { zoom(into: c) }
                        } label: {
                            ZStack {
                                Circle().fill(c.live ? MColor.danger : MColor.textPrimary).frame(width: c.places.count == 1 ? 30 : 40, height: c.places.count == 1 ? 30 : 40)
                                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                                if c.places.count == 1 { Glyph(.home, size: 16).foregroundStyle(MColor.background) }
                                else { Text("\(c.moments)").font(.caption.weight(.bold)).foregroundStyle(MColor.background) }
                            }
                        }
                        .accessibilityLabel(c.places.count == 1 ? "\(c.places[0].name), \(c.moments) Moments" : "\(c.places.count) places, \(c.moments) Moments")
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
            .mapControls { MapCompass(); MapScaleView() }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                region = ctx.region
                refreshTask?.cancel()
                refreshTask = Task { try? await Task.sleep(for: .milliseconds(250)); guard !Task.isCancelled else { return }; await load(ctx.region) }
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: MSpacing.s) {
                HStack(spacing: MSpacing.s) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(MColor.textSecondary)
                        TextField("Places, Moments, @people", text: $query).textFieldStyle(.plain).autocorrectionDisabled().accessibilityIdentifier("exploreSearch")
                        if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(MColor.textTertiary) }.accessibilityLabel("Clear") }
                    }
                    .padding(.horizontal, MSpacing.m).padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button { Task { await goToMe() } } label: { Image(systemName: "location").frame(width: 42, height: 42).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous)) }
                        .accessibilityLabel("Near me").accessibilityIdentifier("enableNearby")
                }
                if !query.isBlank { searchResults }
                else {
                    HStack {
                        Text(summary).font(MFont.caption).foregroundStyle(MColor.textSecondary).padding(.horizontal, 10).padding(.vertical, 6).background(.regularMaterial, in: Capsule())
                        Spacer()
                        NavigationLink(value: SocialRoute.meet) {
                            HStack(spacing: 5) { Image(systemName: "heart.fill"); Text("Meet") }.font(MFont.caption.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(LinearGradient(colors: [.pink, .pink.opacity(0.75)], startPoint: .top, endPoint: .bottom)))
                        }
                        .accessibilityIdentifier("meetLink")
                        Button { showList.toggle() } label: { Label(showList ? "Map" : "List", systemImage: showList ? "map" : "list.bullet").font(MFont.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6).background(.regularMaterial, in: Capsule()) }
                            .accessibilityIdentifier("exploreListToggle")
                    }
                }
            }
            .padding(.horizontal, MSpacing.m).padding(.top, MSpacing.s)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("exploreControls")
        }
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showList) {
            NavigationStack { NearbyView(embedded: true).socialDestinations() }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedPlace) { p in
            NavigationStack { PlaceView(place: p).socialDestinations() }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .task(id: query) { people = query.isBlank ? [] : await env.social.search(people: query) }
        .accessibilityIdentifier("exploreMap")
        .task {
            // First paint: if the phone knows where it is, start there instead of a spinning globe.
            if let here = env.location.current { position = .region(MKCoordinateRegion(center: here, latitudinalMeters: 8000, longitudinalMeters: 8000)) }
        }
    }

    // MARK: Clustering (grid cells sized to the visible span, so zooming out merges pins)

    private var clusters: [Cluster] {
        let span = region?.span.longitudeDelta ?? 360
        let cell = max(0.002, span / 6)
        var buckets: [String: (places: [SocialPlace], moments: Int, live: Bool, lat: Double, lon: Double, n: Int)] = [:]
        var byPlace: [String: (SocialPlace, Int, Bool)] = [:]
        for m in env.social.exploreMoments.values { if let p = m.place, query.isBlank || m.title.lowercased().contains(query.lowercased()) || p.name.lowercased().contains(query.lowercased()) { let e = byPlace[p.id] ?? (p, 0, false); byPlace[p.id] = (p, e.1 + 1, e.2 || m.isLive) } }
        for n in env.social.exploreNow.values { if let p = n.place, byPlace[p.id] == nil { byPlace[p.id] = (p, 0, true) } }
        for (_, v) in byPlace {
            let key = "\(Int((v.0.latitude / cell).rounded()))_\(Int((v.0.longitude / cell).rounded()))"
            var b = buckets[key] ?? ([], 0, false, 0, 0, 0)
            b.places.append(v.0); b.moments += v.1; b.live = b.live || v.2; b.lat += v.0.latitude; b.lon += v.0.longitude; b.n += 1
            buckets[key] = b
        }
        return buckets.map { Cluster(id: $0.key, coordinate: CLLocationCoordinate2D(latitude: $0.value.lat / Double($0.value.n), longitude: $0.value.lon / Double($0.value.n)), places: $0.value.places, moments: $0.value.moments, live: $0.value.live) }
    }

    private var summary: String {
        let m = env.social.exploreMoments.count, live = env.social.exploreMoments.values.filter(\.isLive).count, here = env.social.exploreNow.count
        if loading && m == 0 { return "Looking…" }
        if m == 0 && here == 0 { return "Nothing public in view yet" }
        return [m > 0 ? "\(m) Moments" : nil, live > 0 ? "\(live) live" : nil, here > 0 ? "\(here) here now" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(people.prefix(3)) { u in
                NavigationLink(value: SocialRoute.profile(u.id)) {
                    HStack(spacing: MSpacing.s) { AvatarView(userID: u.id, name: u.displayName, size: 32); VStack(alignment: .leading, spacing: 1) { Text(u.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary); Text("@\(u.handle)").font(MFont.caption).foregroundStyle(MColor.textSecondary) }; Spacer() }
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            let matches = env.social.exploreMoments.values.filter { $0.title.lowercased().contains(query.lowercased()) || ($0.place?.name.lowercased().contains(query.lowercased()) ?? false) || ($0.coarsePlace?.lowercased().contains(query.lowercased()) ?? false) }.prefix(5)
            ForEach(Array(matches)) { m in
                Button { if let p = m.place { position = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude), latitudinalMeters: 3000, longitudinalMeters: 3000)); query = "" } else { env.social.pendingMomentID = m.id } } label: {
                    HStack(spacing: MSpacing.s) { SocialImage(ref: m.coverRef).frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 8)); VStack(alignment: .leading, spacing: 1) { Text(m.title).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary); Text(m.place?.name ?? m.coarsePlace ?? m.dateLabel).font(MFont.caption).foregroundStyle(MColor.textSecondary) }; Spacer() }
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            if people.isEmpty && matches.isEmpty { Text("No matches in view. Zoom out or try another word.").font(MFont.footnote).foregroundStyle(MColor.textSecondary).padding(.vertical, 8) }
        }
        .padding(.horizontal, MSpacing.m)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Actions

    private func load(_ r: MKCoordinateRegion) async {
        loading = true; defer { loading = false }
        let km = max(r.span.latitudeDelta, r.span.longitudeDelta) * 111 / 2
        await env.social.refreshExplore(latitude: r.center.latitude, longitude: r.center.longitude, radiusKm: km)
    }

    private func zoom(into c: Cluster) {
        let span = max(0.01, (region?.span.longitudeDelta ?? 10) / 4)
        withAnimation(.easeInOut(duration: 0.6)) { position = .region(MKCoordinateRegion(center: c.coordinate, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))) }
    }

    private func goToMe() async {
        guard let here = await env.location.locate() else { return }
        withAnimation(.easeInOut(duration: 0.8)) { position = .region(MKCoordinateRegion(center: here, latitudinalMeters: 6000, longitudinalMeters: 6000)) }
    }
}
