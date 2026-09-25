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
    /// The song the link resolved to (title, artist, preview, artwork), looked up as you type.
    @State private var song: SoundtrackMatch?
    @State private var isResolvingSong = false
    /// The title was filled from the song (so a new link may replace it; a typed one stays).
    @State private var titleIsFromSong = false
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
                if kind == .soundtrack { soundtrackSection }
                Section {
                    TextField(kind == .event ? "Event name" : (kind == .soundtrack ? "Title (optional, uses the song name)" : "Title"), text: $title)
                        .onChange(of: title) { _, value in
                            if value.count > BeaconFormRules.maxTitleLength { title = String(value.prefix(BeaconFormRules.maxTitleLength)) }
                            if value != song?.trackName { titleIsFromSong = false }
                        }
                    TextField(kind == .event ? "What's happening? (markdown ok)" : "Details (optional)", text: $details, axis: .vertical)
                        .lineLimit(2...6)
                        .onChange(of: details) { _, value in
                            let limit = kind == .event ? 10_000 : BeaconFormRules.maxBeaconDescription
                            if value.count > limit { details = String(value.prefix(limit)) }
                        }
                }
                Section("Where") {
                    BeaconPlacePicker(place: $place, fallback: fallback)
                }
                photoSection
                switch kind {
                case .event:
                    Section("When") {
                        DatePicker("Starts", selection: $start, in: (isEditing ? Date.distantPast : Date())...)
                            .onChange(of: start) { oldStart, newStart in
                                // Keep the same length when the start moves; never end before it starts.
                                if end <= newStart {
                                    end = newStart.addingTimeInterval(max(3600, end.timeIntervalSince(oldStart)))
                                }
                            }
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
                    EmptyView()   // link and song card sit at the top
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
                        .disabled(!canPost)
                }
            }
            .interactiveDismissDisabled(isSaving)
            // The preview keeps playing while the form scrolls; it stops when the form closes.
            .onDisappear { SoundtrackPreviewPlayer.shared.stop() }
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

    /// Soundtracks need only a valid link (the title falls back to the song); others a title.
    private var canPost: Bool {
        guard !isSaving else { return false }
        if kind == .soundtrack { return BeaconFormRules.isMusicLink(musicURL) }
        return title.nonEmptyTrimmed != nil
    }

    // MARK: - Sections

    private var soundtrackSection: some View {
        Section {
            HStack {
                TextField("Song link (Spotify, Apple Music, YouTube)", text: $musicURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if musicURL.isEmpty {
                    Button {
                        if let pasted = UIPasteboard.general.string { musicURL = pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if isResolvingSong {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finding the song…").foregroundStyle(ClickColors.textSecondary)
                }
                .font(ClickTypography.supporting)
            } else if let song {
                SoundtrackPreviewCard(trackName: song.trackName, artistName: song.artistName,
                                      artworkURL: song.artworkURL, previewURL: song.previewURL, seed: musicURL)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
        } header: {
            Text("Song")
        } footer: {
            if !musicURL.isEmpty, !BeaconFormRules.isMusicLink(musicURL) {
                Text("Use an https link from Spotify, Apple Music or YouTube (Music).")
                    .foregroundStyle(ClickColors.destructive)
            } else if !musicURL.isEmpty, !isResolvingSong, song == nil {
                Text("Couldn't identify the song. You can still post it; add a title so people know what it is.")
            }
        }
        .task(id: musicURL) { await resolveSong() }
    }

    /// Debounced lookup; autofills the title unless the user typed their own.
    private func resolveSong() async {
        guard BeaconFormRules.isMusicLink(musicURL) else {
            song = nil
            isResolvingSong = false
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isResolvingSong = true
        let match = await SoundtrackResolver.resolve(musicURL)
        guard !Task.isCancelled else { return }
        isResolvingSong = false
        song = match
        if let match, title.nonEmptyTrimmed == nil || titleIsFromSong {
            title = match.trackName
            titleIsFromSong = true
        }
    }

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
            } else if kind == .soundtrack, let art = song?.artworkURL {
                // With no photo, a soundtrack's banner is its album art.
                EventVisual(seed: musicURL, imageURL: art, cornerRadius: 12)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        Text("Album art (default)")
                            .font(ClickTypography.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
            }
            let hasPhoto = photo != nil || (existingImageURL != nil && !removeExistingImage)
            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(hasPhoto ? "Replace" : "Photo Library", systemImage: "photo.on.rectangle")
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
        // A soundtrack's album art is its default banner, not an uploaded photo.
        existingImageURL = beacon.imageURL == beacon.albumArtURL ? nil : beacon.imageURL
        if kind == .soundtrack {
            title = beacon.trackName == nil ? beacon.title : ""
            if let track = beacon.trackName {
                song = SoundtrackMatch(trackName: track, artistName: beacon.artistName, previewURL: beacon.previewURL, artworkURL: beacon.albumArtURL)
                title = track
                titleIsFromSong = true
            }
        }
    }

    private func save() async {
        guard canPost else { return }
        let name = title.nonEmptyTrimmed ?? (kind == .soundtrack ? song?.trackName : nil)
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

        var metadata: [String: Any] = [:]
        if let name { metadata["title"] = name }
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
            // Resolved on device; the server keeps these when its own lookup misses.
            if let song {
                metadata["track_name"] = song.trackName
                if let artist = song.artistName { metadata["artist_name"] = artist }
                if let preview = song.previewURL { metadata["preview_url"] = preview }
                if let art = song.artworkURL { metadata["album_art_url"] = art }
            }
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
            self.error = Self.serverReason(error) ?? error.userFacingMessage
        }
    }

    /// The server's validation message ("metadata.title is too long"), made readable.
    static func serverReason(_ error: any Error) -> String? {
        guard case .validation(_, let body?)? = error as? APIError,
              let data = body.data(using: .utf8),
              let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String,
              !reason.isEmpty else { return nil }
        let readable = reason.replacingOccurrences(of: "metadata.", with: "").replacingOccurrences(of: "_", with: " ")
        return readable.prefix(1).uppercased() + readable.dropFirst() + (readable.hasSuffix(".") ? "" : ".")
    }
}
