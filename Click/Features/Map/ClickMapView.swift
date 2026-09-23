import SwiftUI
import MapKit
import CoreLocation

public struct ClickMapView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var userLocation: CLLocationCoordinate2D?
    @State private var beacons: [NativeMapBeacon] = []
    @State private var selectedBeacon: NativeMapBeacon?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var locationTask: Task<Void, Never>?

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera, selection: $selectedBeacon) {
                UserAnnotation()

                ForEach(beacons) { beacon in
                    Annotation(beacon.title, coordinate: beacon.coordinate, anchor: .bottom) {
                        BeaconMarker(beacon: beacon)
                    }
                    .tag(beacon)
                }
            }
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 10) {
                HStack {
                    Spacer()
                    Button {
                        if let userLocation {
                            camera = .region(
                                MKCoordinateRegion(
                                    center: userLocation,
                                    latitudinalMeters: 2_500,
                                    longitudinalMeters: 2_500
                                )
                            )
                        } else {
                            Task { await requestLocationAndStart() }
                        }
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Center on my location")
                }

                nearbyPanel
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await requestLocationAndStart() }
        .onDisappear {
            locationTask?.cancel()
            locationTask = nil
        }
        .sheet(item: $selectedBeacon) { beacon in
            BeaconDetailSheet(beacon: beacon)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var nearbyPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nearby")
                        .font(ClickTypography.titleMedium)
                        .foregroundStyle(ClickColors.textPrimary)
                    Text(nearbySubtitle)
                        .font(ClickTypography.microcopy)
                        .foregroundStyle(ClickColors.textSecondary)
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await loadNearby() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh nearby places")
                }
            }

            if let loadError {
                Text(loadError)
                    .font(ClickTypography.captionSmall)
                    .foregroundStyle(ClickColors.textSecondary)
            }

            if !beacons.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 9) {
                        ForEach(beacons.prefix(8)) { beacon in
                            Button {
                                selectedBeacon = beacon
                                camera = .region(
                                    MKCoordinateRegion(
                                        center: beacon.coordinate,
                                        latitudinalMeters: 1_200,
                                        longitudinalMeters: 1_200
                                    )
                                )
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: beacon.systemImage)
                                        .foregroundStyle(ClickColors.primary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(beacon.title)
                                            .font(ClickTypography.captionSmall)
                                            .foregroundStyle(ClickColors.textPrimary)
                                            .lineLimit(1)
                                        Text(beacon.kindLabel)
                                            .font(ClickTypography.microcopy)
                                            .foregroundStyle(ClickColors.textSecondary)
                                    }
                                }
                                .padding(.horizontal, 11)
                                .frame(height: 48)
                                .background(ClickColors.surfaceContainerLow)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(ClickColors.quietBorder.opacity(0.45), lineWidth: 1)
        }
    }

    private var nearbySubtitle: String {
        if userLocation == nil {
            return "Enable location to load nearby Click activity"
        }
        if beacons.isEmpty {
            return isLoading ? "Looking around you…" : "No active beacons nearby"
        }
        return "\(beacons.count) active near you"
    }

    @MainActor
    private func requestLocationAndStart() async {
        let current = env.permissions.status(for: .locationWhenInUse)
        let resolved = current == .notDetermined
            ? await env.permissions.requestPermission(for: .locationWhenInUse)
            : current

        guard resolved == .authorized else {
            loadError = "Location access is off. The map remains available, but nearby activity cannot be loaded."
            return
        }

        if locationTask == nil {
            locationTask = Task {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        guard !Task.isCancelled else { return }
                        guard let coordinate = update.location?.coordinate else { continue }
                        await MainActor.run {
                            let firstFix = userLocation == nil
                            userLocation = coordinate
                            if firstFix {
                                camera = .region(
                                    MKCoordinateRegion(
                                        center: coordinate,
                                        latitudinalMeters: 4_000,
                                        longitudinalMeters: 4_000
                                    )
                                )
                                Task { await loadNearby() }
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        loadError = "Couldn't update your location."
                    }
                }
            }
        }
    }

    @MainActor
    private func loadNearby() async {
        guard let userLocation else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let request = APIRequest(
                path: "/api/map/beacons",
                method: .get,
                queryItems: [
                    URLQueryItem(name: "lat", value: String(userLocation.latitude)),
                    URLQueryItem(name: "lng", value: String(userLocation.longitude)),
                    URLQueryItem(name: "radius_meters", value: "5000")
                ],
                requiresAuth: true
            )
            let (data, _) = try await env.api.executeRaw(request)
            beacons = try NativeMapBeacon.decodeList(from: data)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct BeaconMarker: View {
    let beacon: NativeMapBeacon

    var body: some View {
        ZStack {
            Circle()
                .fill(ClickColors.primary)
                .frame(width: 38, height: 38)
                .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
            Image(systemName: beacon.systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

private struct BeaconDetailSheet: View {
    let beacon: NativeMapBeacon

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 13) {
                    ZStack {
                        Circle()
                            .fill(ClickColors.primary.opacity(0.16))
                            .frame(width: 52, height: 52)
                        Image(systemName: beacon.systemImage)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(ClickColors.primary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(beacon.title)
                            .font(ClickTypography.titleLarge)
                        Text(beacon.kindLabel)
                            .font(ClickTypography.bodySmall)
                            .foregroundStyle(ClickColors.textSecondary)
                    }
                }

                if let creator = beacon.creatorName, !creator.isEmpty {
                    Label("Shared by \(creator)", systemImage: "person.fill")
                        .font(ClickTypography.bodySmall)
                        .foregroundStyle(ClickColors.textSecondary)
                }

                if let description = beacon.descriptionText, !description.isEmpty {
                    Text(description)
                        .font(ClickTypography.bodyMedium)
                        .foregroundStyle(ClickColors.textPrimary)
                }

                Spacer()
            }
            .padding(20)
            .background(ClickColors.background.ignoresSafeArea())
            .navigationTitle("Nearby")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct NativeMapBeacon: Identifiable, Hashable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let type: String
    let title: String
    let creatorName: String?
    let descriptionText: String?

    static func == (lhs: NativeMapBeacon, rhs: NativeMapBeacon) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var kindLabel: String {
        switch type {
        case "event": return "Event"
        case "recreation": return "Social spot"
        case "soundtrack": return "Soundtrack"
        case "study": return "Study"
        case "hobby": return "Community"
        case "transit": return "Transit"
        case "hazard", "hazard_utility": return "Alert"
        case "utility": return "Utility"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var systemImage: String {
        switch type {
        case "event": return "calendar"
        case "recreation": return "person.2.fill"
        case "soundtrack": return "music.note"
        case "study": return "book.fill"
        case "hobby": return "sparkles"
        case "transit": return "tram.fill"
        case "hazard", "hazard_utility": return "exclamationmark.triangle.fill"
        case "utility": return "wrench.adjustable.fill"
        case "sos": return "sos"
        default: return "mappin"
        }
    }

    static func decodeList(from data: Data) throws -> [NativeMapBeacon] {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = root["beacons"] as? [[String: Any]]
        else {
            throw APIError.decoding
        }

        return rows.compactMap { row in
            guard
                let id = row["id"] as? String,
                let type = row["beacon_type"] as? String,
                let lat = number(row["lat"]),
                let lng = number(row["lng"])
            else {
                return nil
            }

            let metadata = row["metadata"] as? [String: Any] ?? [:]
            let title = firstString(metadata, keys: ["label", "title", "name", "track_name"])
                ?? type.replacingOccurrences(of: "_", with: " ").capitalized
            let description = firstString(metadata, keys: ["description", "text", "message", "body"])

            return NativeMapBeacon(
                id: id,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                type: type,
                title: title,
                creatorName: row["creator_name"] as? String,
                descriptionText: description
            )
        }
    }

    private static func firstString(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { return clean }
            }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}


public enum MapRouteDetailKind: Sendable {
    case beacon
    case hub
}

public struct MapRouteDetailView: View {
    @Environment(AppEnvironment.self) private var env

    public let kind: MapRouteDetailKind
    public let id: String

    @State private var title = "Loading…"
    @State private var subtitle: String?
    @State private var detail: String?
    @State private var systemImage = "mappin"
    @State private var isLoading = true
    @State private var errorMessage: String?

    public init(kind: MapRouteDetailKind, id: String) {
        self.kind = kind
        self.id = id
    }

    public var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .tint(ClickColors.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load this item", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") {
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ClickColors.primary)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(ClickColors.primary.opacity(0.14))
                                    .frame(width: 56, height: 56)
                                Image(systemName: systemImage)
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(ClickColors.primary)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(title)
                                    .font(ClickTypography.headlineSmall)
                                    .foregroundStyle(ClickColors.textPrimary)
                                if let subtitle {
                                    Text(subtitle)
                                        .font(ClickTypography.bodySmall)
                                        .foregroundStyle(ClickColors.textSecondary)
                                }
                            }
                        }

                        if let detail, !detail.isEmpty {
                            Text(detail)
                                .font(ClickTypography.bodyMedium)
                                .foregroundStyle(ClickColors.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            }
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle(kind == .hub ? "Community Hub" : "Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task { await load() }
    }

    @MainActor
    private func load() async {
        guard !id.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            switch kind {
            case .beacon:
                let request = APIRequest(
                    path: "/api/beacons/\(id)",
                    method: .get,
                    requiresAuth: true
                )
                let (data, _) = try await env.api.executeRaw(request)
                guard
                    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let beacon = root["beacon"] as? [String: Any]
                else { throw APIError.decoding }

                let metadata = beacon["metadata"] as? [String: Any] ?? [:]
                let type = (beacon["beacon_type"] as? String) ?? "event"
                title =
                    firstString(metadata, keys: ["title", "label", "name", "track_name"])
                    ?? type.replacingOccurrences(of: "_", with: " ").capitalized
                subtitle = firstString(metadata, keys: ["location_name", "place_name", "venue_name"])
                detail = firstString(metadata, keys: ["description", "text", "message", "body"])
                systemImage = type == "event" ? "calendar" : "mappin"
                errorMessage = nil

            case .hub:
                let request = APIRequest(
                    path: "/api/hub/\(id)",
                    method: .get,
                    requiresAuth: true
                )
                let (data, _) = try await env.api.executeRaw(request)
                guard
                    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let hub = root["hub"] as? [String: Any]
                else { throw APIError.decoding }

                title = (hub["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Community Hub"
                subtitle = hub["category"] as? String
                detail = nil
                systemImage = "person.3.fill"
                errorMessage = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func firstString(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let raw = dictionary[key] as? String {
                let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { return clean }
            }
        }
        return nil
    }
}
