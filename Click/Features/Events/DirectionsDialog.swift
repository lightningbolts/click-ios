import MapKit
import SwiftUI

/// A place to open outside Click. Only the destination leaves the app; the user's location is
/// never sent.
struct MapsDestination: Identifiable, Equatable {
    let coordinate: CLLocationCoordinate2D
    let name: String
    let address: String?
    /// Directions (from Directions) vs. just showing the place (tapping the location).
    let wantsDirections: Bool

    var id: String { "\(coordinate.latitude),\(coordinate.longitude),\(wantsDirections)" }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.name == rhs.name }

    @MainActor
    func openInAppleMaps() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        item.openInMaps(launchOptions: wantsDirections ? [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault] : nil)
    }

    /// The Google Maps app when it's installed, else Google Maps on the web.
    @MainActor
    func openInGoogleMaps() {
        let point = "\(coordinate.latitude),\(coordinate.longitude)"
        let app = wantsDirections ? "comgooglemaps://?daddr=\(point)" : "comgooglemaps://?q=\(point)&center=\(point)"
        let web = wantsDirections
            ? "https://www.google.com/maps/dir/?api=1&destination=\(point)"
            : "https://www.google.com/maps/search/?api=1&query=\(point)"
        Task { @MainActor in
            if let url = URL(string: app), await UIApplication.shared.open(url) { return }
            if let url = URL(string: web) { _ = await UIApplication.shared.open(url) }
        }
    }
}

extension View {
    /// "Open in…" for a place: Apple Maps, Google Maps, then (when given) Click's own map, and
    /// Copy Address. One dialog for the event's Directions tile and its location card.
    func mapsDialog(_ destination: Binding<MapsDestination?>, onClickMap: (() -> Void)? = nil) -> some View {
        confirmationDialog(
            destination.wrappedValue?.wantsDirections == true ? "Get directions" : (destination.wrappedValue?.name ?? "Open in"),
            isPresented: Binding(get: { destination.wrappedValue != nil }, set: { if !$0 { destination.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: destination.wrappedValue
        ) { target in
            Button("Apple Maps") { target.openInAppleMaps() }
            Button("Google Maps") { target.openInGoogleMaps() }
            if let onClickMap {
                Button("Show on Click Map", action: onClickMap)
            }
            if let address = target.address {
                Button("Copy Address") {
                    UIPasteboard.general.string = address
                    ClickHaptics.success()
                }
            }
        } message: { target in
            if let address = target.address { Text(address) }
        }
    }
}
