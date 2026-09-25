import SwiftUI

/// Hub details (spec §61): category (the owner can change it), kind, geofence radius, who's
/// here now, and members.
struct HubInfoView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let hub: HubInfo
    /// Called after the owner saves a change, so the chat reloads the hub.
    let onChanged: () -> Void

    @State private var members = ModuleState<HubMembers>()
    @State private var people: [String: UserIdentity] = [:]
    @State private var category: String
    @State private var saving = false
    @State private var error: String?

    init(hub: HubInfo, onChanged: @escaping () -> Void) {
        self.hub = hub
        self.onChanged = onChanged
        _category = State(initialValue: hub.category ?? HubCategory.general.rawValue)
    }

    private var isOwner: Bool { hub.creatorID == env.session.currentSession?.userId }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Type", value: hub.isEventHub ? "Event hub" : "Community hub")
                    if isOwner, !hub.isEventHub {
                        Picker("Category", selection: $category) {
                            ForEach(HubCategory.allCases) { Text($0.label).tag($0.rawValue) }
                            if HubCategory(rawValue: category) == nil { Text(category.capitalized).tag(category) }
                        }
                        .disabled(saving)
                    } else if let label = hub.category.map(Self.label) {
                        LabeledContent("Category", value: label)
                    }
                    if let radius = hub.radiusMeters, !hub.isEventHub {
                        LabeledContent("Reach", value: "Within \(radius) m")
                    }
                    if let count = members.value?.occupantCount {
                        LabeledContent("Here now", value: count == 1 ? "1 person" : "\(count) people")
                    }
                } footer: {
                    Text(hub.isEventHub
                         ? "Guests who RSVP'd can chat here."
                         : "People nearby can join and post while they're within reach.")
                }
                Section("Members") {
                    if let ids = members.value?.participantIDs {
                        ForEach(ids, id: \.self) { id in
                            HStack(spacing: 12) {
                                AvatarView(imageURL: people[id]?.avatarURL, seed: id,
                                           initials: String((people[id]?.name ?? "?").prefix(1)), size: 36)
                                Text(id == env.session.currentSession?.userId ? "You" : people[id]?.name ?? "Click user")
                                    .foregroundStyle(ClickColors.textPrimary)
                                Spacer()
                                if id == hub.creatorID {
                                    Text("Owner").font(ClickTypography.caption).foregroundStyle(ClickColors.textSecondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } else if members.errorMessage != nil {
                        Button("Couldn't load members. Try again") { Task { await load() } }
                    } else {
                        ProgressView()
                    }
                }
            }
            .navigationTitle(hub.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: category) { old, new in
                guard new != old, new != hub.category else { return }
                Task { await save(category: new, revertTo: old) }
            }
            .alert("Couldn't update the hub", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .task { await load() }
    }

    nonisolated static func label(_ raw: String) -> String {
        HubCategory(rawValue: raw.lowercased())?.label ?? raw.capitalized
    }

    private func load() async {
        members.begin()
        do {
            let loaded = try await env.hubs.members(hubID: hub.id)
            members.succeed(loaded)
            people = await env.identities.resolve(loaded.participantIDs)
        } catch {
            members.fail(error)
        }
    }

    private func save(category new: String, revertTo old: String) async {
        saving = true
        defer { saving = false }
        do {
            try await env.hubs.update(hubID: hub.id, category: new)
            ClickHaptics.success()
            onChanged()
        } catch {
            category = old
            self.error = error.userFacingMessage
        }
    }
}
