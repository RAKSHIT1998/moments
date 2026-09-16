import SwiftUI
import MapKit
import CoreLocation

/// Where life happened: one pin per coarse place (city-level, geocoded on device). Never exact.
struct MomentMapView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var pins: [Pin] = []
    @State private var scope = 0   // 0 mine, 1 friends
    @State private var position: MapCameraPosition = .automatic
    @State private var selected: Pin?

    struct Pin: Identifiable, Hashable { let id: String; let place: String; let coordinate: CLLocationCoordinate2D; let moments: [SocialMoment]
        static func == (a: Pin, b: Pin) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) } }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position) {
                ForEach(pins) { pin in
                    Annotation(pin.place, coordinate: pin.coordinate) {
                        ZStack {
                            Circle().fill(MColor.accentGradient).frame(width: 44, height: 44).shadow(color: MColor.accent.opacity(0.4), radius: 8, y: 4)
                            if let cover = pin.moments.first?.coverRef { SocialImage(ref: cover).frame(width: 40, height: 40).clipShape(Circle()) }
                            Text("\(pin.moments.count)").font(.caption2.weight(.bold)).foregroundStyle(.white).padding(4).background(MColor.accent, in: Circle()).offset(x: 16, y: -16)
                        }
                        .onTapGesture { selected = pin }
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
            .ignoresSafeArea(edges: .bottom)
            Picker("Scope", selection: $scope) { Text("My map").tag(0); Text("Friends' map").tag(1) }.pickerStyle(.segmented).padding(MSpacing.l).background(.ultraThinMaterial)
        }
        .navigationTitle("Moment Map").navigationBarTitleDisplayMode(.inline)
        .task(id: scope) { await load() }
        .sheet(item: $selected) { pin in
            NavigationStack {
                List(pin.moments) { m in NavigationLink(value: SocialRoute.moment(m.id)) { HStack { SocialImage(ref: m.coverRef).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10)); VStack(alignment: .leading) { Text(m.title); Text(m.dateLabel).font(MFont.caption).foregroundStyle(MColor.textSecondary) } } } }
                    .navigationTitle(pin.place).navigationBarTitleDisplayMode(.inline).socialDestinations()
            }
            .presentationDetents([.medium])
        }
        .overlay(alignment: .bottom) {
            if pins.isEmpty { Text("Add a place to a Moment and it shows up here.").font(MFont.footnote).foregroundStyle(MColor.textSecondary).padding(MSpacing.m).background(.ultraThinMaterial, in: Capsule()).padding(.bottom, MSpacing.xl) }
        }
        .accessibilityIdentifier("momentMap")
    }

    private func load() async {
        let source = scope == 0 ? env.social.momentsImIn : env.social.moments.values.filter { !$0.memberIDs.contains(env.social.myID) && $0.memberIDs.contains { env.social.isFriend($0) } }
        let grouped = Dictionary(grouping: source.filter { !($0.coarsePlace ?? "").isEmpty }, by: { $0.coarsePlace! })
        var out: [Pin] = []
        for (place, ms) in grouped {
            if let c = await PlaceGeocoder.shared.coordinate(for: place) { out.append(Pin(id: place, place: place, coordinate: c, moments: ms.sorted { $0.createdAt > $1.createdAt })) }
        }
        pins = out.sorted { $0.moments.count > $1.moments.count }
        if let first = pins.first { position = .region(MKCoordinateRegion(center: first.coordinate, span: MKCoordinateSpan(latitudeDelta: 12, longitudeDelta: 12))) }
    }
}

/// City-level forward geocoding with an on-device cache. Only ever fed a coarse place name.
actor PlaceGeocoder {
    static let shared = PlaceGeocoder()
    private var cache: [String: CLLocationCoordinate2D] = [:]
    private let geocoder = CLGeocoder()
    func coordinate(for place: String) async -> CLLocationCoordinate2D? {
        if let c = cache[place] { return c }
        guard let mark = try? await geocoder.geocodeAddressString(place).first, let loc = mark.location else { return nil }
        cache[place] = loc.coordinate
        return loc.coordinate
    }
}
