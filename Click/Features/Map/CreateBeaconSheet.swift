import SwiftUI

/// Map "+": drop a beacon or create an event at your location (spec §54). Field rules mirror
/// click-web `POST /api/beacons`; the server remains the validator.
struct CreateBeaconSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    /// Fallback position when no location fix is available (the map's center).
    let fallback: CLLocationCoordinate2D?
    let onCreated: (MapBeacon) -> Void

    enum Kind: String, CaseIterable, Identifiable {
        case event, social = "social_vibe", study, soundtrack, hazard, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .event: "Event"
            case .social: "Social"
            case .study: "Study"
            case .soundtrack: "Soundtrack"
            case .hazard: "Heads-up"
            case .other: "Other"
            }
        }
        var symbol: String { BeaconKind(raw: rawValue).systemImage }
    }

    static let categories = ["Social", "Tech", "Music", "Sports", "Food", "Study", "Arts", "Outdoors", "Networking", "Party", "Wellness", "Gaming"]

    @State private var kind: Kind = .event
    @State private var title = ""
    @State private var details = ""
    @State private var place = ""
    @State private var start = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
    @State private var end = Calendar.current.date(byAdding: .hour, value: 3, to: .now) ?? .now
    @State private var categories: Set<String> = []
    @State private var visibility = "public"
    @State private var capacityText = ""
    @State private var approvalRequired = false
    @State private var hostsOnlyGuestList = false
    @State private var musicURL = ""
    @State private var hours = 4.0
    @State private var showName = true
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Kind.allCases) { option in
                                Button { kind = option } label: {
                                    Label(option.label, systemImage: option.symbol)
                                        .font(ClickTypography.supporting)
                                        .padding(.horizontal, 12)
                                        .frame(minHeight: 34)
                                        .foregroundStyle(kind == option ? ClickColors.accentForeground : ClickColors.textSecondary)
                                        .background(kind == option ? ClickColors.selectionTint : ClickColors.fillSubtle, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                Section {
                    TextField(kind == .event ? "Event name" : "Title", text: $title)
                    TextField(kind == .event ? "What's happening? (markdown ok)" : "Details (optional)", text: $details, axis: .vertical)
                        .lineLimit(2...6)
                    TextField("Place name (optional)", text: $place)
                }
                switch kind {
                case .event:
                    Section("When") {
                        DatePicker("Starts", selection: $start, in: Date()...)
                        DatePicker("Ends", selection: $end, in: start...)
                    }
                    Section("Categories") {
                        FlowLayout(spacing: 7) {
                            ForEach(Self.categories, id: \.self) { tag in
                                let on = categories.contains(tag)
                                Button {
                                    if on { categories.remove(tag) } else if categories.count < 3 { categories.insert(tag) }
                                } label: {
                                    Text(tag)
                                        .font(ClickTypography.supporting)
                                        .padding(.horizontal, 12)
                                        .frame(minHeight: 30)
                                        .foregroundStyle(on ? ClickColors.accentForeground : ClickColors.textSecondary)
                                        .background(on ? ClickColors.selectionTint : ClickColors.fillSubtle, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Section("Who can join") {
                        Picker("Visibility", selection: $visibility) {
                            Text("Public").tag("public")
                            Text("Unlisted").tag("unlisted")
                            Text("Invite only").tag("invite_only")
                        }
                        TextField("Capacity (optional)", text: $capacityText).keyboardType(.numberPad)
                        Toggle("Approve requests to join", isOn: $approvalRequired)
                        Toggle("Only hosts see the guest list", isOn: $hostsOnlyGuestList)
                    }
                case .soundtrack:
                    Section { TextField("Song link (Spotify, Apple Music, YouTube…)", text: $musicURL).keyboardType(.URL).textInputAutocapitalization(.never) }
                default:
                    Section {
                        VStack(alignment: .leading) {
                            Text("Visible for \(Int(hours)) hour\(hours == 1 ? "" : "s")")
                            Slider(value: $hours, in: 1...24, step: 1)
                        }
                    }
                }
                Section {
                    Toggle("Show my name", isOn: $showName)
                } footer: {
                    Text("Placed at your current location.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(ClickColors.destructive) }
                }
            }
            .navigationTitle(kind == .event ? "New Event" : "Drop a Beacon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Posting…" : "Post") { Task { await save() } }
                        .disabled(title.nonEmptyTrimmed == nil || isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func save() async {
        guard let name = title.nonEmptyTrimmed else { return }
        isSaving = true
        defer { isSaving = false }
        let fix = await env.location.currentLocation(maximumAge: 120, acceptableAccuracy: 150, timeout: .seconds(6))
        guard let coordinate = fix?.coordinate ?? fallback else {
            error = "Turn on location so the beacon lands where you are."
            return
        }
        var metadata: [String: Any] = ["title": name]
        if let text = details.nonEmptyTrimmed { metadata["description"] = text }
        if let placeName = place.nonEmptyTrimmed { metadata["location_name"] = placeName }
        var body: [String: Any] = [
            "kind": kind.rawValue, "lat": coordinate.latitude, "lon": coordinate.longitude,
            "show_creator_name": showName
        ]
        switch kind {
        case .event:
            let iso = ISO8601DateFormatter()
            metadata["event_start_at"] = iso.string(from: start)
            metadata["event_end_at"] = iso.string(from: end)
            if !categories.isEmpty { metadata["event_categories"] = Array(categories) }
            body["event_visibility"] = visibility
            body["approval_required"] = approvalRequired
            body["guest_list_visibility"] = hostsOnlyGuestList ? "hosts_only" : "public"
            if let capacity = Int(capacityText), capacity > 0 { body["event_capacity"] = capacity }
            body["event_timezone"] = TimeZone.current.identifier
        case .soundtrack:
            guard let link = musicURL.nonEmptyTrimmed else {
                error = "Add a song link."
                return
            }
            metadata["music_url"] = link
        default:
            body["ttl_ms"] = Int(hours * 3_600_000)
        }
        body["metadata"] = metadata
        do {
            let created = try await env.beacons.create(body: body)
            ClickHaptics.success()
            dismiss()
            onCreated(created)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

import CoreLocation
