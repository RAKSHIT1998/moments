import Foundation
import CoreLocation
import MapKit

/// One-shot, when-in-use location. The coordinate stays in memory on this device and is only
/// used to ask the backend "what's within N km?" — it is never written anywhere.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var status: CLAuthorizationStatus
    private(set) var current: CLLocationCoordinate2D?
    private(set) var lastError: String?
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        #if DEBUG
        // Simulator/tests: Mumbai, near the seeded venues, unless a real fix arrives.
        if ProcessInfo.processInfo.arguments.contains("-uitest") || ProcessInfo.processInfo.arguments.contains("-demo") { current = CLLocationCoordinate2D(latitude: 19.06, longitude: 72.83) }
        #endif
    }

    var isAuthorized: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }
    var isDenied: Bool { status == .denied || status == .restricted }

    /// Asks once if needed, then returns a coordinate (or nil if refused / unavailable).
    func locate() async -> CLLocationCoordinate2D? {
        if status == .notDetermined { manager.requestWhenInUseAuthorization(); return await withCheckedContinuation { continuation = $0 } }
        guard isAuthorized else { return current }
        manager.requestLocation()
        return await withCheckedContinuation { continuation = $0 }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            status = m.authorizationStatus
            if isAuthorized { m.requestLocation() } else if let c = continuation { continuation = nil; c.resume(returning: current) }
        }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let c = locations.last?.coordinate
        Task { @MainActor in
            if let c { current = c }
            if let k = continuation { continuation = nil; k.resume(returning: current) }
        }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            lastError = error.localizedDescription
            if let k = continuation { continuation = nil; k.resume(returning: current) }
        }
    }
}

/// Venue search backed by Apple Maps: cafés, bars, beaches, venues near a point.
enum PlaceSearch {
    static func search(_ query: String, near c: CLLocationCoordinate2D?) async -> [SocialPlace] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query.isBlank ? "cafe restaurant bar" : query
        request.resultTypes = [.pointOfInterest, .address]
        if let c { request.region = MKCoordinateRegion(center: c, latitudinalMeters: 5000, longitudinalMeters: 5000) }
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        return response.mapItems.prefix(20).compactMap { item in
            guard let name = item.name else { return nil }
            let loc = item.placemark.coordinate
            let area = [item.placemark.subLocality, item.placemark.locality].compactMap { $0 }.joined(separator: ", ")
            return SocialPlace(id: SocialPlace.makeID(name: name, latitude: loc.latitude, longitude: loc.longitude), name: name, area: area, latitude: loc.latitude, longitude: loc.longitude, category: item.pointOfInterestCategory?.rawValue.replacingOccurrences(of: "MKPOICategory", with: ""))
        }
    }
}
