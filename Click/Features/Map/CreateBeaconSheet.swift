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

    /// `recurrence.frequency` values accepted by `POST /api/beacons` (click-web `eventRecurrence.ts`).
    enum Repeat: String, CaseIterable, Identifiable {
        case daily, weekly, biweekly, monthly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .biweekly: "Every 2 Weeks"
            case .monthly: "Monthly"
            }
        }
    }

    /// Total occurrences, including the first (server bounds).
    static let occurrenceRange = 2...26

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
    /// The link `song` was resolved from. Form sections are rebuilt as they scroll back into
    /// view (restarting their tasks); an already-resolved link must not look up again, or the
    /// card flickers to "Finding the song…" and shifts.
    @State private var resolvedMusicURL: String?
    @State private var isResolvingSong = false
    /// Finding a song by name (the default) instead of pasting a link.
    @State private var songQuery = ""
    @State private var songResults: [SoundtrackMatch] = []
    @State private var isSearchingSongs = false
    @State private var pastesLink = false
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
    @State private var repeatRule: Repeat?
    @State private var occurrences = 4
    /// The form as it opened; anything else is unsaved work a stray swipe must not throw away.
    @State private var baseline: Draft?
    @State private var confirmingDiscard = false

    /// Everything the user fills in (the kind chip alone is not work worth guarding).
    private struct Draft: Equatable {
        var title, details, customCategory, visibility, capacityText, musicURL: String
        var place: BeaconPlace?
        var start, end: Date
        var categories: Set<String>
        var approvalRequired, hostsOnlyGuestList, showName, hasNewPhoto, removeExistingImage: Bool
        var hours: Double
        var repeatRule: Repeat?
        var occurrences: Int
    }

    private var draft: Draft {
        Draft(title: title, details: details, customCategory: customCategory, visibility: visibility,
              capacityText: capacityText, musicURL: musicURL, place: place, start: start, end: end,
              categories: categories, approvalRequired: approvalRequired, hostsOnlyGuestList: hostsOnlyGuestList,
              showName: showName, hasNewPhoto: photo != nil, removeExistingImage: removeExistingImage,
              hours: hours, repeatRule: repeatRule, occurrences: occurrences)
    }

    private var hasUnsavedChanges: Bool { baseline.map { $0 != draft } ?? false }

    private var isEditing: Bool { editing != nil }

    /// Events happen at a place the host picks; every other beacon marks where you are right now.
    private var picksPlace: Bool { kind == .event }

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
                whereSection
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
                        if !isEditing {
                            Picker("Repeats", selection: $repeatRule) {
                                Text("Never").tag(Repeat?.none)
                                ForEach(Repeat.allCases) { Text($0.label).tag(Repeat?.some($0)) }
                            }
                            if repeatRule != nil {
                                Stepper("\(occurrences) events", value: $occurrences, in: Self.occurrenceRange)
                            }
                        }
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasUnsavedChanges { confirmingDiscard = true } else { dismiss() }
                    }
                    .confirmation(isEditing ? "Discard your changes?" : "Discard this \(kind == .event ? "event" : "beacon")?",
                                  isPresented: $confirmingDiscard, keep: "Keep Editing") {
                        Button(isEditing ? "Discard Changes" : "Discard", role: .destructive) { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? (isEditing ? "Saving…" : "Posting…") : (isEditing ? "Save" : "Post")) { Task { await save() } }
                        .disabled(!canPost)
                }
            }
            // A swipe down must not silently throw away a half-filled form; Cancel asks first.
            .interactiveDismissDisabled(isSaving || hasUnsavedChanges)
            // The preview keeps playing while the form scrolls; it stops when the form closes.
            .onDisappear { SoundtrackPreviewPlayer.shared.stop() }
            .onAppear(perform: prefill)
            // A beacon drops where you are: have the fix ready by the time Post is tapped.
            .task(id: picksPlace) {
                guard !picksPlace, !isEditing else { return }
                _ = await env.location.currentLocation(maximumAge: 120, acceptableAccuracy: 150, timeout: .seconds(6))
            }
            .onChange(of: kind) { _, new in
                // Alerts stay short by default (spec F4); people nearby extend them if it's still there.
                guard !isEditing, new == .hazard, env.features.isEnabled(.alertConfirmations), hours == 4 else { return }
                hours = 2
                baseline?.hours = 2
            }
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

    private var whereSection: some View {
        Section {
            if picksPlace {
                BeaconPlacePicker(place: $place, fallback: fallback)
            } else {
                Label(isEditing ? "Where you dropped it" : "Your current location",
                      systemImage: isEditing ? "mappin.and.ellipse" : "location.fill")
            }
        } header: {
            Text("Where")
        } footer: {
            if !picksPlace {
                Text(isEditing ? "Beacons stay where they were dropped." : "Beacons drop where you are, so people nearby know it's happening now.")
            }
        }
    }

    /// Find a song by name in Click (the iTunes catalog); pasting a link is the fallback.
    private var soundtrackSection: some View {
        Section {
            if let song {
                SoundtrackPreviewCard(trackName: song.trackName, artistName: song.artistName,
                                      artworkURL: song.artworkURL, previewURL: song.previewURL, seed: musicURL)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                Button("Choose a different song", systemImage: "arrow.triangle.2.circlepath", action: clearSong)
            } else if pastesLink {
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
                if isResolvingSong { progressRow("Finding the song…") }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ClickColors.textTertiary)
                    TextField("Search songs or artists", text: $songQuery)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                }
                if isSearchingSongs && songResults.isEmpty { progressRow("Searching…") }
                ForEach(songResults, id: \.link) { match in
                    Button { choose(match) } label: { songRow(match) }
                        .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Song")
        } footer: {
            if song == nil {
                VStack(alignment: .leading, spacing: 6) {
                    if pastesLink, !musicURL.isEmpty, !BeaconFormRules.isMusicLink(musicURL) {
                        Text("Use an https link from Spotify, Apple Music or YouTube (Music).")
                            .foregroundStyle(ClickColors.destructive)
                    } else if pastesLink, !musicURL.isEmpty, !isResolvingSong {
                        Text("Couldn't identify the song. You can still post it; add a title so people know what it is.")
                    } else if !pastesLink, songQuery.count >= 2, !isSearchingSongs, songResults.isEmpty {
                        Text("No songs found. Try another spelling, or paste a link.")
                    }
                    Button(pastesLink ? "Search for a song instead" : "Have a link? Paste it instead") {
                        pastesLink.toggle()
                        musicURL = ""
                    }
                    .font(ClickTypography.supportingEmphasized)
                }
            }
        }
        .task(id: musicURL) { await resolveSong() }
        .task(id: songQuery) { await searchSongs() }
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).foregroundStyle(ClickColors.textSecondary)
        }
        .font(ClickTypography.supporting)
    }

    private func songRow(_ match: SoundtrackMatch) -> some View {
        HStack(spacing: 12) {
            EventVisual(seed: match.link ?? match.trackName, imageURL: match.artworkURL, symbol: "music.note", cornerRadius: 8)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(match.trackName)
                    .font(ClickTypography.body)
                    .foregroundStyle(ClickColors.textPrimary)
                if let artist = match.artistName {
                    Text(artist)
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// Debounced catalog search as you type.
    private func searchSongs() async {
        let term = songQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else {
            songResults = []
            isSearchingSongs = false
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        isSearchingSongs = true
        let results = await SoundtrackResolver.search(term)
        guard !Task.isCancelled else { return }
        isSearchingSongs = false
        withAnimation(ClickMotion.content) { songResults = results }
    }

    private func choose(_ match: SoundtrackMatch) {
        ClickHaptics.selection()
        musicURL = match.link ?? ""
        resolvedMusicURL = musicURL   // already identified: no lookup
        songQuery = ""
        songResults = []
        adopt(match)
    }

    private func clearSong() {
        SoundtrackPreviewPlayer.shared.stop()
        song = nil
        musicURL = ""
        resolvedMusicURL = nil
        if titleIsFromSong {
            title = ""
            titleIsFromSong = false
        }
    }

    /// Shows the song and names the soundtrack after it, unless the user typed their own title.
    private func adopt(_ match: SoundtrackMatch?) {
        song = match
        if let match, title.nonEmptyTrimmed == nil || titleIsFromSong {
            title = match.trackName
            titleIsFromSong = true
        }
    }

    /// Debounced lookup of a pasted link; autofills the title unless the user typed their own.
    private func resolveSong() async {
        guard musicURL != resolvedMusicURL else { return }
        guard BeaconFormRules.isMusicLink(musicURL) else {
            song = nil
            resolvedMusicURL = nil
            isResolvingSong = false
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isResolvingSong = true
        let match = await SoundtrackResolver.resolve(musicURL)
        guard !Task.isCancelled else { return }
        isResolvingSong = false
        resolvedMusicURL = musicURL
        adopt(match)
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
        defer { baseline = draft }
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
            // A saved link the catalog never identified stays editable as a link.
            pastesLink = song == nil && !musicURL.isEmpty
        }
    }

    private func save() async {
        guard canPost else { return }
        let name = title.nonEmptyTrimmed ?? (kind == .soundtrack ? song?.trackName : nil)
        isSaving = true
        defer { isSaving = false }
        error = nil

        // A beacon keeps where it was dropped; a new one lands where you are, never the map's center.
        let pickedPlace = picksPlace ? place : nil
        var coordinate = pickedPlace?.coordinate ?? (picksPlace ? nil : editing?.coordinate)
        if coordinate == nil {
            // Posting is the intent to share where you are: ask, if location was never decided.
            _ = await env.permissions.requestPermission(for: .locationWhenInUse)
            let here = await env.location.currentLocation(maximumAge: 120, acceptableAccuracy: 150, timeout: .seconds(6))?.coordinate
            coordinate = here ?? (picksPlace ? fallback : nil)
        }
        guard let coordinate else {
            error = picksPlace ? "Choose a place, or turn on location so it lands where you are."
                : env.location.isAuthorized ? "Couldn't find where you are. Try again in a moment."
                : "Turn on location in Settings to drop a beacon where you are."
            return
        }

        var metadata: [String: Any] = [:]
        if let name { metadata["title"] = name }
        metadata["description"] = details.nonEmptyTrimmed ?? (isEditing ? "" : nil)
        if let place = pickedPlace {
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
            if !isEditing, let repeatRule {
                body["recurrence"] = ["frequency": repeatRule.rawValue, "count": occurrences]
            }
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
