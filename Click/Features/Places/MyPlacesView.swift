import SwiftUI

/// Me → Places (§6.10): the Places you've checked in at or met people at. Your own history only.
struct MyPlacesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var visits = ModuleState<[MyPlaceVisit]>()

    var body: some View {
        Group {
            if !env.features.isEnabled(.clickPlaces) {
                ContentUnavailableView("Not available", systemImage: "mappin.slash")
            } else if let visits = visits.value {
                if visits.isEmpty {
                    ContentUnavailableView(
                        "No Places yet",
                        systemImage: "building.2",
                        description: Text("Check in at a Click Place and it shows up here.")
                    )
                } else {
                    List(visits) { visit in
                        NavigationLink(value: AppRoute.place(idOrSlug: visit.place.id, anchorToken: nil)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(visit.place.name).font(ClickTypography.bodyEmphasized)
                                Text(Self.visitsLine(visit))
                                    .font(ClickTypography.supporting)
                                    .foregroundStyle(ClickColors.textSecondary)
                                if visit.encounterCount > 0 {
                                    Text(visit.encounterCount == 1 ? "Met 1 person here" : "Met \(visit.encounterCount) people here")
                                        .font(ClickTypography.supporting)
                                        .foregroundStyle(ClickColors.textSecondary)
                                }
                            }
                        }
                    }
                }
            } else if let message = visits.errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load your Places", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            } else {
                ClickLoadingView()
            }
        }
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard env.features.isEnabled(.clickPlaces) else { return }
        visits.begin()
        do {
            visits.succeed(try await env.places.myPlaces())
        } catch {
            if !error.isCancellation { visits.fail(error) }
        }
    }

    /// "4 visits · Last Sep 28".
    static func visitsLine(_ visit: MyPlaceVisit) -> String {
        let count = visit.checkInCount == 1 ? "1 visit" : "\(visit.checkInCount) visits"
        guard let last = visit.lastCheckInAt else { return count }
        return "\(count) · Last \(last.formatted(.dateTime.month(.abbreviated).day()))"
    }
}
