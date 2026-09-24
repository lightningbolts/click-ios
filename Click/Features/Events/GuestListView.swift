import SwiftUI

/// Creator-only guest list import and matching (spec §58, `/api/beacons/{id}/guest-list`).
struct GuestListView: View {
    @Environment(AppEnvironment.self) private var env
    let beaconID: String

    @State private var status = ModuleState<GuestListStatus>()
    @State private var pasted = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if let value = status.value {
                    LabeledContent("Guests", value: "\(value.uploaded)")
                    LabeledContent("On Click", value: "\(value.matched)")
                    if value.teasers > 0 { LabeledContent("Invites ready", value: "\(value.teasers)") }
                } else if status.isPending {
                    ProgressView()
                } else {
                    Button("Couldn't load the guest list. Retry") { Task { await load() } }
                }
            } footer: {
                Text("Matching uses emails and Instagram handles. Guests never see who else is on the list.")
            }

            Section {
                TextField("Paste emails or @handles, one per line (or CSV)", text: $pasted, axis: .vertical)
                    .lineLimit(4...10)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(working ? "Importing…" : "Import") { Task { await upload() } }
                    .disabled(working || pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Import")
            } footer: {
                if let error { Text(error).foregroundStyle(ClickColors.destructive) }
            }

            if let entries = status.value?.entries, !entries.isEmpty {
                Section {
                    Button("Match again") { Task { await rematch() } }.disabled(working)
                    ForEach(entries) { entry in
                        HStack {
                            Text(entry.label)
                            Spacer()
                            if entry.matched {
                                Label("On Click", systemImage: "checkmark.circle.fill")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(ClickColors.accentForeground)
                                    .accessibilityLabel("Matched")
                            }
                        }
                    }
                } header: {
                    Text("Guests")
                }
            }
        }
        .navigationTitle("Guest list")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        status.begin()
        do { status.succeed(try await env.events.guestList(beaconID: beaconID)) } catch { status.fail(error) }
    }

    private func upload() async {
        working = true
        defer { working = false }
        do {
            status.succeed(try await env.events.uploadGuestList(beaconID: beaconID, text: pasted))
            pasted = ""
            error = nil
        } catch {
            self.error = "Import failed. \(error.userFacingMessage)"
        }
    }

    private func rematch() async {
        working = true
        defer { working = false }
        do { status.succeed(try await env.events.rematchGuestList(beaconID: beaconID)) } catch {
            self.error = "Matching failed. \(error.userFacingMessage)"
        }
    }
}
