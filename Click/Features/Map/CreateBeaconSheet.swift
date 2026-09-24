import CoreLocation
import PhotosUI
import SwiftUI

/// Map "+": drop a beacon or create an event (spec §54), and the creator's edit form for an
/// existing one (`editing`). Field rules mirror click-web `POST/PATCH /api/beacons`; the server
/// remains the validator.
struct CreateBeaconSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    /// Fallback position when no location fix is available (the map's center).
    let fallback: CLLocationCoordinate2D?
    var editing: MapBeacon? = nil
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
    @State private var place: BeaconPlace?
    @State private var start = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
    @State private var end = Calendar.current.date(byAdding: .hour, value: 3, to: .now) ?? .now
    @State private var categories: Set<String> = []
    @State private var customCategory = ""
    @State private var visibility = "public"
    @State private var capacityText = ""
    @State private var approvalRequired = false
    @State private var hostsOnlyGuestList = false
    @State private var musicURL = ""
    @State private var hours = 4.0
    @State private var showName = true
    @State private var photo: UIImage?
    @State private var existingImageURL: String?
    @State private var removeExistingImage = false
    @State private var photoItem: PhotosPickerItem?
    @State private var takingPhoto = false
    @State private var isSaving = false
    @State private var error: String?
    @State private var didPrefill = false

    private var isEditing: Bool { editing != nil }

    var body: some View {
        NavigationStack {
            Form {
                if !isEditing { kindPicker }
                Section {
                    TextField(kind == .event ? "Event name" : "Title", text: $title)
                    TextField(kind == .event ? "What's happening? (markdown ok)" : "Details (optional)", text: $details, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section("Where") {
                    BeaconPlacePicker(place: $place, fallback: fallback)
                }
                photoSection
                switch kind {
                case .event:
                    Section("When") {
                        DatePicker("Starts", selection: $start, in: (isEditing ? Date.distantPast : Date())...)
                        DatePicker("Ends", selection: $end, in: start...)
                    }
                    categoriesSection
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
                    Section {
                        TextField("Song link (Spotify, Apple Music, YouTube…)", text: $musicURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                    } footer: {
                        if !musicURL.isEmpty, !BeaconFormRules.isMusicLink(musicURL) {
                            Text("Use a link from Spotify, Apple Music, YouTube, SoundCloud, Tidal, Deezer or Bandcamp.")
                                .foregroundStyle(ClickColors.destructive)
                        }
                    }
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
                }
                if let error {
                    Section { Text(error).foregroundStyle(ClickColors.destructive) }
                }
            }
            .navigationTitle(isEditing ? "Edit" : (kind == .event ? "New Event" : "Drop a Beacon"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? (isEditing ? "Saving…" : "Posting…") : (isEditing ? "Save" : "Post")) { Task { await save() } }
                        .disabled(title.nonEmptyTrimmed == nil || isSaving || (kind == .soundtrack && !BeaconFormRules.isMusicLink(musicURL)))
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onAppear(perform: prefill)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        photo = image
                        removeExistingImage = false
                    } else {
                        error = "Couldn't read that photo."
                    }
                }
            }
            .fullScreenCover(isPresented: $takingPhoto) {
                CameraCapture { image in
                    takingPhoto = false
                    if let image {
                        photo = image
                        removeExistingImage = false
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Sections

    private var kindPicker: some View {
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
    }

    /// Photo on every beacon type (spec §54): library or camera, shown at the 4:3 cover crop.
    private var photoSection: some View {
        Section("Photo") {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("Selected photo, cropped to the cover shape")
            } else if let existingImageURL, !removeExistingImage {
                EventVisual(seed: editing?.id ?? "", imageURL: existingImageURL, cornerRadius: 12)
                    .aspectRatio(4 / 3, contentMode: .fit)
            }
            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(photo == nil && (existingImageURL == nil || removeExistingImage) ? "Photo Library" : "Replace", systemImage: "photo.on.rectangle")
                }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Spacer()
                    Button { takingPhoto = true } label: { Label("Take Photo", systemImage: "camera") }
                        .buttonStyle(.borderless)
                }
            }
            if photo != nil || (existingImageURL != nil && !removeExistingImage) {
                Button("Remove photo", role: .destructive) {
                    photo = nil
                    removeExistingImage = existingImageURL != nil
                }
            }
        }
    }

    private var categoriesSection: some View {
        Section {
            FlowLayout(spacing: 7) {
                ForEach(Self.categories + categories.filter { !Self.categories.contains($0) }.sorted(), id: \.self) { tag in
                    let on = categories.contains(tag)
                    Button {
                        if on { categories.remove(tag) } else if categories.count < BeaconFormRules.maxCategories { categories.insert(tag) }
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
            HStack {
                TextField("Add your own (\(BeaconFormRules.maxCategoryLength) max)", text: $customCategory)
                    .onSubmit(addCustomCategory)
                    .onChange(of: customCategory) { _, value in
                        if value.count > BeaconFormRules.maxCategoryLength { customCategory = String(value.prefix(BeaconFormRules.maxCategoryLength)) }
                    }
                Button("Add", action: addCustomCategory)
                    .disabled(categories.count >= BeaconFormRules.maxCategories
                              || BeaconFormRules.customCategory(customCategory, existing: categories) == nil)
            }
        } header: {
            Text("Categories")
        } footer: {
            Text("Up to \(BeaconFormRules.maxCategories).")
        }
    }

    private func addCustomCategory() {
        guard categories.count < BeaconFormRules.maxCategories,
              let clean = BeaconFormRules.customCategory(customCategory, existing: categories) else { return }
        categories.insert(clean)
        customCategory = ""
    }

    // MARK: - Prefill / save

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        guard let beacon = editing else { return }
        kind = Kind(rawValue: beacon.rawType) ?? (beacon.isEvent ? .event : .other)
        title = beacon.title
        details = beacon.description ?? ""
        place = BeaconPlace(name: beacon.locationName ?? "Pinned location", formattedAddress: beacon.formattedAddress, coordinate: beacon.coordinate)
        if let schedule = beacon.schedule {
            start = schedule.start
            end = schedule.end
        }
        categories = Set(beacon.eventCategories)
        visibility = beacon.visibility ?? "public"
        capacityText = beacon.capacity.map(String.init) ?? ""
        approvalRequired = beacon.approvalRequired ?? false
        musicURL = beacon.musicURL ?? ""
        showName = beacon.showCreatorName
        existingImageURL = beacon.imageURL
    }

    private func save() async {
        guard let name = title.nonEmptyTrimmed else { return }
        isSaving = true
        defer { isSaving = false }
        error = nil

        var coordinate = place?.coordinate
        if coordinate == nil {
            coordinate = await env.location.currentLocation(maximumAge: 120, acceptableAccuracy: 150, timeout: .seconds(6))?.coordinate ?? fallback
        }
        guard let coordinate else {
            error = "Choose a place, or turn on location so it lands where you are."
            return
        }

        var metadata: [String: Any] = ["title": name]
        metadata["description"] = details.nonEmptyTrimmed ?? (isEditing ? "" : nil)
        if let place {
            metadata["location_name"] = place.name
            if let address = place.formattedAddress { metadata["formatted_address"] = address }
        }
        if let photo {
            guard let jpeg = await BeaconFormRules.compressedJPEG(photo) else {
                error = "That photo is too large to upload."
                return
            }
            do {
                metadata["image_url"] = try await env.beacons.uploadImage(jpeg: jpeg)
            } catch {
                self.error = "The photo didn't upload. \(error.userFacingMessage)"
                return
            }
        } else if removeExistingImage {
            metadata["image_url"] = NSNull()
        }

        var body: [String: Any] = ["show_creator_name": showName, "lat": coordinate.latitude, "lon": coordinate.longitude]
        switch kind {
        case .event:
            let iso = ISO8601DateFormatter()
            metadata["event_start_at"] = iso.string(from: start)
            metadata["event_end_at"] = iso.string(from: end)
            metadata["event_categories"] = Array(categories)
            body["event_visibility"] = visibility
            body["approval_required"] = approvalRequired
            body["guest_list_visibility"] = hostsOnlyGuestList ? "hosts_only" : "public"
            if let capacity = Int(capacityText), capacity > 0 { body["event_capacity"] = capacity }
            body["event_timezone"] = TimeZone.current.identifier
        case .soundtrack:
            guard BeaconFormRules.isMusicLink(musicURL) else {
                error = "Add a song link from a music service."
                return
            }
            metadata["music_url"] = musicURL.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            if !isEditing { body["ttl_ms"] = Int(hours * 3_600_000) }
        }
        body["metadata"] = metadata.compactMapValues { $0 }

        do {
            if !isEditing { body["kind"] = kind.rawValue }
            let json = try JSONSerialization.data(withJSONObject: body)
            let saved: MapBeacon
            if let editing {
                saved = try await env.beacons.update(id: editing.id, json: json)
            } else {
                saved = try await env.beacons.create(json: json)
            }
            ClickHaptics.success()
            dismiss()
            onCreated(saved)
        } catch {
            self.error = error.userFacingMessage
        }
    }
}
