import CoreLocation
import MapKit
import Observation
import SwiftUI
import UIKit

/// Client-side checks that mirror `POST/PATCH /api/beacons` so the form explains problems
/// before posting (the server stays the validator).
enum BeaconFormRules {
    static let maxCategories = 3
    static let maxCategoryLength = 24
    static let maxImageBytes = 2_000_000
    /// Server limits (`POST /api/beacons`): title 80, non-event description 500.
    static let maxTitleLength = 80
    static let maxBeaconDescription = 500
    /// Exactly the server's allowlist (`isAllowedMusicShareUrl`): anything else is rejected
    /// on post, so the form must not accept it.
    static let musicHosts = ["open.spotify.com", "spotify.link", "music.apple.com", "itunes.apple.com",
                             "youtube.com", "www.youtube.com", "music.youtube.com", "youtu.be"]

    /// A cleaned custom category, or nil when empty/too long/duplicate.
    nonisolated static func customCategory(_ raw: String, existing: Set<String>) -> String? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= maxCategoryLength else { return nil }
        guard !existing.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { return nil }
        return clean
    }

    /// Soundtrack links must be http(s) links to a known music service.
    nonisolated static func isMusicLink(_ raw: String) -> Bool {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return musicHosts.contains { host == $0 || ($0 != "youtube.com" && host.hasSuffix("." + $0)) }
    }

    /// JPEG under the server's 2 MB cap, downscaled off the main actor.
    static func compressedJPEG(_ image: UIImage) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            var side: CGFloat = 1600
            var quality: CGFloat = 0.82
            for _ in 0..<6 {
                let scale = min(1, side / max(image.size.width, image.size.height))
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                if let data = resized.jpegData(compressionQuality: quality), data.count <= maxImageBytes { return data }
                side *= 0.8
                quality -= 0.08
            }
            return nil
        }.value
    }
}

/// A place chosen for a beacon: name, address and coordinate.
struct BeaconPlace: Equatable {
    var name: String
    var formattedAddress: String?
    var coordinate: CLLocationCoordinate2D

    static func == (lhs: BeaconPlace, rhs: BeaconPlace) -> Bool {
        lhs.name == rhs.name && lhs.formattedAddress == rhs.formattedAddress
            && lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

/// `MKLocalSearchCompleter` wrapper for the create sheet's place field.
@Observable
@MainActor
final class PlaceSearchModel: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    var query = "" {
        didSet { completer.queryFragment = query }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    func bias(to coordinate: CLLocationCoordinate2D) {
        completer.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> BeaconPlace? {
        guard let item = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start().mapItems.first else { return nil }
        let address = [completion.subtitle].first { !$0.isEmpty }
        return BeaconPlace(name: item.name ?? completion.title, formattedAddress: address, coordinate: item.placemark.coordinate)
    }

    // The completer calls back on the main thread (it was created there).
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = Array(completer.results.prefix(6))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }

    /// Readable name for a coordinate (also resolves legacy "Current location" labels).
    static func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async -> (name: String?, address: String?) {
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)).first else {
            return (nil, nil)
        }
        let name = placemark.areasOfInterest?.first ?? placemark.name
        let address = [placemark.subThoroughfare.map { "\($0) \(placemark.thoroughfare ?? "")" } ?? placemark.thoroughfare, placemark.locality]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
        return (name, address.isEmpty ? nil : address)
    }
}

/// Place field: search suggestions, "Use current location", and a map preview whose centre
/// pin you move by dragging the map.
struct BeaconPlacePicker: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var place: BeaconPlace?
    let fallback: CLLocationCoordinate2D?

    @State private var search = PlaceSearchModel()
    @State private var camera: MapCameraPosition = .automatic
    @State private var locating = false
    @State private var isSearching = false

    var body: some View {
        Group {
            TextField("Search for a place", text: $search.query)
                .textInputAutocapitalization(.words)
                .onChange(of: search.query) { _, value in isSearching = !value.isEmpty }
            if isSearching {
                ForEach(search.results, id: \.self) { result in
                    Button {
                        Task { await choose(result) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title).foregroundStyle(ClickColors.textPrimary)
                            if !result.subtitle.isEmpty {
                                Text(result.subtitle).font(ClickTypography.metadata).foregroundStyle(ClickColors.textTertiary)
                            }
                        }
                    }
                }
            }
            Button {
                Task { await useCurrentLocation() }
            } label: {
                Label(locating ? "Finding you…" : "Use current location", systemImage: "location.fill")
            }
            .disabled(locating)
            if let place {
                VStack(alignment: .leading, spacing: 6) {
                    Text(place.name).font(ClickTypography.bodyEmphasized)
                    if let address = place.formattedAddress {
                        Text(address).font(ClickTypography.metadata).foregroundStyle(ClickColors.textTertiary)
                    }
                    Map(position: $camera)
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            Image(systemName: "mappin")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(ClickColors.destructive)
                                .offset(y: -15)
                                .allowsHitTesting(false)
                        }
                        .onMapCameraChange(frequency: .onEnd) { context in
                            moved(to: context.region.center)
                        }
                    Text("Drag the map to fine-tune the pin.")
                        .font(ClickTypography.metadata)
                        .foregroundStyle(ClickColors.textTertiary)
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear {
            if let coordinate = place?.coordinate ?? env.location.lastFix?.coordinate ?? fallback {
                search.bias(to: coordinate)
                camera = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 400, longitudinalMeters: 400))
            }
        }
    }

    private func choose(_ result: MKLocalSearchCompletion) async {
        guard let resolved = await search.resolve(result) else { return }
        place = resolved
        search.query = ""
        isSearching = false
        camera = .region(MKCoordinateRegion(center: resolved.coordinate, latitudinalMeters: 400, longitudinalMeters: 400))
    }

    private func useCurrentLocation() async {
        locating = true
        defer { locating = false }
        guard let fix = await env.location.currentLocation(maximumAge: 60, acceptableAccuracy: 100, timeout: .seconds(6)) else { return }
        let named = await PlaceSearchModel.reverseGeocode(fix.coordinate)
        place = BeaconPlace(name: named.name ?? "Pinned location", formattedAddress: named.address, coordinate: fix.coordinate)
        camera = .region(MKCoordinateRegion(center: fix.coordinate, latitudinalMeters: 400, longitudinalMeters: 400))
    }

    /// Pin moves with the map; the name stays unless the pin left the place (>150 m).
    private func moved(to center: CLLocationCoordinate2D) {
        guard var current = place else { return }
        let distance = CLLocation(latitude: current.coordinate.latitude, longitude: current.coordinate.longitude)
            .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
        guard distance > 2 else { return }
        current.coordinate = center
        place = current
        if distance > 150 {
            Task {
                let named = await PlaceSearchModel.reverseGeocode(center)
                if place?.coordinate.latitude == center.latitude {
                    place?.name = named.name ?? "Pinned location"
                    place?.formattedAddress = named.address
                }
            }
        }
    }
}
