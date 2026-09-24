import SwiftUI

/// Hub categories offered by the current creation flow (KMP `CreateHubModal`).
enum HubCategory: String, CaseIterable, Identifiable {
    case general, music, study, sports, food, nightlife, gaming, tech, art, fitness, networking, party
    var id: String { rawValue }
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Create a permanent community hub at the user's current location (`/api/hub/create`).
struct CreateHubSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var category: HubCategory = .general
    @State private var radius = 50.0
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Hub name", text: $name)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("People within the hub's area can join and chat. Hubs stay until you delete them.")
                }
                Section("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(HubCategory.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                Section {
                    VStack(alignment: .leading) {
                        Text("Area: \(Int(radius)) m around you")
                        Slider(value: $radius, in: 25...500, step: 25)
                    }
                } footer: {
                    Text("Uses your current location once to place the hub.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(ClickColors.destructive) }
                }
            }
            .navigationTitle("Create Community Hub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Creating…" : "Create") { Task { await create() } }
                        .disabled(name.nonEmptyTrimmed == nil || isCreating)
                }
            }
            .interactiveDismissDisabled(isCreating)
        }
    }

    private func create() async {
        guard let hubName = name.nonEmptyTrimmed else { return }
        isCreating = true
        defer { isCreating = false }
        if env.permissions.status(for: .locationWhenInUse) == .notDetermined {
            _ = await env.permissions.requestPermission(for: .locationWhenInUse)
        }
        guard let fix = await env.location.currentLocation(maximumAge: 60, acceptableAccuracy: 100, timeout: .seconds(8)) else {
            error = "Turn on location to place the hub where you are."
            return
        }
        do {
            let hubID = try await env.hubs.create(
                name: hubName,
                category: category.rawValue,
                latitude: fix.coordinate.latitude,
                longitude: fix.coordinate.longitude,
                radiusMeters: Int(radius)
            )
            dismiss()
            env.router.navigate(to: .hub(hubID: hubID))
        } catch {
            self.error = "Couldn't create the hub. \(error.userFacingMessage)"
        }
    }
}

/// Join a hub by its code (the hub ID a venue shares), then open it; access is checked by
/// the server when the hub opens (geofence or event RSVP).
struct JoinHubSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Hub code", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.join)
                        .onSubmit(join)
                } footer: {
                    Text("Ask the venue or host for their hub code. You may need to be nearby to join.")
                }
            }
            .navigationTitle("Join Community Hub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join", action: join).disabled(code.nonEmptyTrimmed == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func join() {
        guard let id = code.nonEmptyTrimmed else { return }
        dismiss()
        env.router.navigate(to: .hub(hubID: id))
    }
}
