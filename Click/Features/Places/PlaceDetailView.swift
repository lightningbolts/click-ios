import SwiftUI

/// A Click Place page. I1 ships the route with a minimal page; the full layout (check-in, Pulse,
/// history) arrives with the Place detail work (spec §6.4).
struct PlaceDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let idOrSlug: String
    let anchorToken: String?

    @State private var detail: PlaceDetail?
    @State private var failed = false

    var body: some View {
        Group {
            if !env.features.isEnabled(.clickPlaces) {
                ContentUnavailableView("Not available", systemImage: "mappin.slash")
            } else if let detail {
                List {
                    Section {
                        Label(detail.summary.category.label, systemImage: detail.summary.category.symbol)
                        if let address = detail.summary.addressLine { Text(address) }
                    }
                }
                .navigationTitle(detail.summary.name)
            } else if failed {
                ContentUnavailableView("This Place isn't available.", systemImage: "mappin.slash")
            } else {
                ProgressView()
            }
        }
        .task(id: idOrSlug) {
            guard env.features.isEnabled(.clickPlaces) else { return }
            do {
                detail = try await env.places.detail(idOrSlug: idOrSlug, source: anchorToken == nil ? "link" : "qr")
            } catch {
                failed = !error.isCancellation
            }
        }
    }
}
