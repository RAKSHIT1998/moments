import SwiftUI
import MapKit
import CoreLocation

/// The places around you on a map: one pin per venue, count badge, tap for the place page.
struct NearbyMapView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var position: MapCameraPosition = .automatic
    @State private var here: CLLocationCoordinate2D?
    @State private var selected: SocialPlace?

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $position) {
                UserAnnotation()
                if let here {
                    ForEach(env.social.nearbyPlaces(latitude: here.latitude, longitude: here.longitude), id: \.place.id) { p in
                        Annotation(p.place.name, coordinate: CLLocationCoordinate2D(latitude: p.place.latitude, longitude: p.place.longitude)) {
                            Button { selected = p.place } label: {
                                ZStack {
                                    Circle().fill(p.live ? MColor.danger : MColor.accent).frame(width: 34, height: 34).shadow(radius: 4, y: 2)
                                    Text("\(max(1, p.moments))").font(.caption.weight(.bold)).foregroundStyle(.white)
                                }
                            }
                            .accessibilityLabel("\(p.place.name), \(p.moments) Moments")
                        }
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .ignoresSafeArea(edges: .bottom)
            if here == nil { Text("Finding you…").font(MFont.footnote).padding(MSpacing.m).background(.ultraThinMaterial, in: Capsule()).padding(.bottom, MSpacing.xl) }
        }
        .navigationTitle("Nearby map").navigationBarTitleDisplayMode(.inline)
        .task {
            here = await env.location.locate()
            if let here {
                await env.social.refreshNearby(latitude: here.latitude, longitude: here.longitude)
                position = .region(MKCoordinateRegion(center: here, latitudinalMeters: env.social.nearbyRadiusKm * 2000, longitudinalMeters: env.social.nearbyRadiusKm * 2000))
            }
        }
        .navigationDestination(item: $selected) { PlaceView(place: $0) }
        .accessibilityIdentifier("nearbyMap")
    }
}
