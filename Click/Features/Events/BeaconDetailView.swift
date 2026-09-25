import MapKit
import SwiftUI

/// The canonical beacon/event detail (spec §55–57), used by every entry point (Home, Saved,
/// Map, deep links, profiles). Actions depend on kind; every engagement write is confirmed by
/// the server before the UI reports it.
struct BeaconDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let beaconID: String

    @State private var beacon = ModuleState<MapBeacon>()
    @State private var isExpired = false
    @State private var rsvp = ModuleState<RSVPState>()
    @State private var engagement = ModuleState<EventEngagement>()
    @State private var rsvpPending = false
    @State private var bookmarkPending = false
    @State private var checkInPending = false
    @State private var notice: String?
    @State private var showingDirectory = false
    @State private var confirmCancelRSVP = false
    @State private var confirmDelete = false
    @State private var people = ModuleState<EventDirectory>()
    @State private var sharingToChat = false
    @State private var editingBeacon = false
    /// Readable place for legacy beacons saved with the label "Current location".
    @State private var resolvedPlace: (name: String?, address: String?)?

    var body: some View {
        Group {
            if let beacon = beacon.value {
                content(beacon)
            } else if let error = beacon.errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load this", systemImage: "mappin.slash")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                        .tint(ClickColors.primaryActionFill)
                }
            } else {
                ClickLoadingView()
            }
        }
        .navigationTitle(beacon.value?.title ?? "")
        .toolbar(.hidden, for: .navigationBar)
        .task { if beacon.value == nil { await load() } }
        .task(id: rsvp.value?.request) { await watchPendingRequest() }
        .alert("Event", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: - Content

    private func content(_ beacon: MapBeacon) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Full-bleed hero (prototype event sheet); uploaded image overrides the pattern.
                EventVisual(seed: beacon.id, imageURL: beacon.imageURL, symbol: beacon.kind.systemImage, cornerRadius: 0)
                    .frame(height: 250)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(alignment: .topTrailing) { headerButtons(beacon).padding(14) }

                VStack(alignment: .leading, spacing: 18) {
                    pills(beacon)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(beacon.title)
                            .font(ClickTypography.identityTitle)
                            .foregroundStyle(ClickColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        hostLine(beacon)
                    }

                    if isExpired {
                        Label("This has ended.", systemImage: "clock.badge.xmark")
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textSecondary)
                    }

                    if beacon.isEvent {
                        if beacon.rsvpEnabled != false, !isExpired { rsvpButton(beacon) }
                        eventActionRow(beacon)
                    } else {
                        beaconActions(beacon)
                    }

                    infoCard(beacon)

                    if let description = beacon.description, !description.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("About")
                                .font(ClickTypography.sectionTitle)
                                .foregroundStyle(ClickColors.textPrimary)
                            Text(Self.markdown(description))
                                .font(ClickTypography.body)
                                .foregroundStyle(ClickColors.textSecondary)
                                .tint(ClickColors.accentForeground)
                                .textSelection(.enabled)
                        }
                    }

                    if beacon.isEvent { peoplePreview }

                    if beacon.creatorID == env.session.currentSession?.userId {
                        if beacon.isEvent {
                            NavigationLink {
                                GuestListView(beaconID: beacon.id)
                            } label: {
                                Label("Guest list", systemImage: "list.bullet.rectangle")
                            }
                        }
                        HStack(spacing: 20) {
                            Button("Edit", systemImage: "pencil") { editingBeacon = true }
                            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(ClickColors.surface)
        .navigationDestination(isPresented: $showingDirectory) {
            EventDirectoryView(beaconID: beacon.id, preloaded: people.value)
        }
        .sheet(isPresented: $sharingToChat) {
            ShareToChatSheet(beacon: beacon)
        }
        .sheet(isPresented: $editingBeacon) {
            CreateBeaconSheet(fallback: nil, editing: beacon) { updated in
                self.beacon.succeed(updated)
                resolvedPlace = nil
            }
        }
        .confirmationDialog("Cancel your RSVP?", isPresented: $confirmCancelRSVP, titleVisibility: .visible) {
            Button(rsvp.value?.isGoing == true ? "Cancel RSVP" : "Withdraw request", role: .destructive) {
                Task { await cancelRSVP(beacon) }
            }
        }
        .confirmationDialog("Delete \(beacon.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete(beacon) } }
        } message: {
            Text("It will be removed for everyone.")
        }
    }

    private func pills(_ beacon: MapBeacon) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let status = EventFormatting.status(beacon.schedule) {
                    StatusPill(status.text, style: status.isLive ? .live : .neutral)
                }
                ForEach(beacon.eventCategories.isEmpty ? [beacon.kind.label] : Array(beacon.eventCategories.prefix(3)), id: \.self) { category in
                    Text(category)
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(ClickColors.fillSubtle, in: Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private func hostLine(_ beacon: MapBeacon) -> some View {
        let posted = beacon.createdAt.map { "posted \($0.formatted(.dateTime.month(.abbreviated).day()))" }
        if let host = beacon.visibleCreatorName {
            HStack(spacing: 8) {
                AvatarView(imageURL: nil, seed: beacon.creatorID, initials: Phase3Repository.initials(from: host), size: 26)
                (Text("Hosted by ").foregroundColor(ClickColors.textSecondary)
                    + Text(host).foregroundColor(ClickColors.textPrimary)
                    + Text(posted.map { " · \($0)" } ?? "").foregroundColor(ClickColors.textSecondary))
                    .font(ClickTypography.supporting)
                    .lineLimit(1)
            }
        } else if let posted {
            Text(posted.prefix(1).uppercased() + posted.dropFirst())
                .font(ClickTypography.supporting)
                .foregroundStyle(ClickColors.textSecondary)
        }
    }

    // MARK: - Event actions

    private func rsvpButton(_ beacon: MapBeacon) -> some View {
        let state = rsvp.value
        let isActive = state?.isGoing == true || state?.request == .pending || state?.request == .waitlisted
        let title: String
        let symbol: String?
        switch (state?.isGoing, state?.request) {
        case (true, _): title = "You're going"; symbol = "checkmark"
        case (_, .pending?): title = "Request sent"; symbol = "clock"
        case (_, .waitlisted?): title = "On the waitlist"; symbol = "list.bullet"
        case (_, .denied?): title = "Request declined"; symbol = nil
        default:
            if rsvp.phase == .loading && state == nil {
                title = ""
                symbol = nil
            } else {
                title = beacon.approvalRequired == true ? "Request to join" : "RSVP"
                symbol = nil
            }
        }
        return Button {
            if isActive { confirmCancelRSVP = true } else { Task { await setRSVP(beacon) } }
        } label: {
            HStack(spacing: 8) {
                if rsvpPending {
                    ProgressView().tint(isActive ? ClickColors.accentForeground : ClickColors.primaryActionForeground)
                } else if let symbol {
                    Image(systemName: symbol).font(.body.weight(.semibold))
                }
                Text(title).font(ClickTypography.button)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(isActive ? ClickColors.accentForeground : ClickColors.primaryActionForeground)
            .background(isActive ? ClickColors.selectionTint : ClickColors.primaryActionFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(rsvpPending || rsvp.value == nil || state?.request == .denied)
        .accessibilityHint(isActive ? "Double-tap to cancel" : "")
    }

    /// Save · Share · Close float over the hero (prototype event sheet header).
    private func headerButtons(_ beacon: MapBeacon) -> some View {
        let saved = engagement.value?.bookmarked == true
        return HStack(spacing: 10) {
            if beacon.isEvent {
                Button { Task { await toggleBookmark(beacon) } } label: {
                    Image(systemName: saved ? "bookmark.fill" : "bookmark")
                        .headerCircle(tint: saved ? ClickColors.accentForeground : .white)
                }
                .disabled(engagement.value == nil || bookmarkPending)
                .accessibilityLabel(saved ? "Remove from saved" : "Save event")
            }
            Menu {
                Button("Copy link", systemImage: "link") {
                    UIPasteboard.general.string = "https://joinclick.co/e/\(beacon.id)"
                    ClickHaptics.success()
                }
                Button("Share to chat", systemImage: "bubble.left") { sharingToChat = true }
                Button("View on Map", systemImage: "map") { env.router.showOnMap(.place(beacon.id)) }
                ShareLink(item: URL(string: "https://joinclick.co/e/\(beacon.id)")!, subject: Text(beacon.title)) {
                    Label("More…", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "square.and.arrow.up").headerCircle(tint: .white)
            }
            .accessibilityLabel("Share")
            Button { dismiss() } label: {
                Image(systemName: "xmark").headerCircle(tint: .white)
            }
            .accessibilityLabel("Close")
        }
        .buttonStyle(.plain)
    }

    /// Event chat · Check in · Directions — equal-width labelled icon actions.
    private func eventActionRow(_ beacon: MapBeacon) -> some View {
        let checkedIn = engagement.value?.checkedIn == true
        let canCheckIn = !isExpired && (rsvp.value?.isGoing == true || beacon.schedule?.isLive() == true || checkedIn)
        return HStack(spacing: 0) {
            iconAction("Event chat", systemImage: "bubble.left") {
                env.router.navigate(to: .eventChat(beaconID: beacon.id))
            }
            iconAction(checkedIn ? "Checked in" : "Check in", systemImage: checkedIn ? "checkmark" : "location",
                       tint: checkedIn ? ClickColors.online : nil, busy: checkInPending) {
                Task { await toggleCheckIn(beacon) }
            }
            .disabled(!canCheckIn || engagement.value == nil || checkInPending)
            .opacity(canCheckIn ? 1 : 0.45)
            iconAction("Directions", systemImage: "location.north.line") { openDirections(beacon) }
        }
    }

    private func iconAction(_ title: String, systemImage: String, tint: Color? = nil, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    if busy { ProgressView() } else {
                        Image(systemName: systemImage).font(.system(size: 22, weight: .regular))
                    }
                }
                .frame(height: 26)
                Text(title).font(ClickTypography.supporting)
            }
            .foregroundStyle(tint ?? ClickColors.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Info card (time · place · people)

    private func infoCard(_ beacon: MapBeacon) -> some View {
        VStack(spacing: 0) {
            if let schedule = beacon.schedule {
                infoRow(systemImage: "clock", title: EventFormatting.when(schedule), subtitle: relativeTime(schedule))
                Divider().padding(.leading, 56)
            }
            Button {
                env.router.showOnMap(.place(beacon.id))
            } label: {
                let label = Self.displayPlace(beacon, resolved: resolvedPlace)
                infoRow(
                    systemImage: "mappin.and.ellipse",
                    title: label.title ?? "Show on map",
                    subtitle: label.subtitle,
                    chevron: true
                )
                .task(id: beacon.id) {
                    guard Self.needsReverseGeocode(beacon), resolvedPlace == nil else { return }
                    resolvedPlace = await PlaceSearchModel.reverseGeocode(beacon.coordinate)
                }
            }
            .buttonStyle(.plain)
            if beacon.isEvent {
                Divider().padding(.leading, 56)
                Button { showingDirectory = true } label: {
                    infoRow(systemImage: "person.2", title: peopleTitle(beacon), subtitle: peopleSubtitle(beacon), chevron: true)
                }
                .buttonStyle(.plain)
            }
        }
        .background(ClickColors.fillSubtle, in: RoundedRectangle(cornerRadius: ClickRadius.surface, style: .continuous))
    }

    private func infoRow(systemImage: String, title: String, subtitle: String?, chevron: Bool = false) -> some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(ClickColors.textPrimary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ClickTypography.body)
                    .foregroundStyle(ClickColors.textPrimary)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ClickColors.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func relativeTime(_ schedule: EventSchedule, now: Date = .now) -> String? {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        if schedule.isEnded(at: now) { return "Ended" }
        if schedule.isLive(at: now) {
            return "Started " + formatter.localizedString(for: schedule.start, relativeTo: now)
        }
        return "Starts " + formatter.localizedString(for: schedule.start, relativeTo: now)
    }

    private func peopleTitle(_ beacon: MapBeacon) -> String {
        guard let count = rsvp.value?.count else { return "People" }
        if let capacity = beacon.capacity { return "\(count) of \(capacity) going" }
        return count == 1 ? "1 going" : "\(count) going"
    }

    private func peopleSubtitle(_ beacon: MapBeacon) -> String? {
        var parts: [String] = []
        if let here = engagement.value?.checkInCount, here > 0 { parts.append("\(here) here now") }
        if let scale = beacon.venueScale?.nonEmptyTrimmed { parts.append(scale.prefix(1).uppercased() + scale.dropFirst()) }
        return parts.isEmpty ? "See who's going" : parts.joined(separator: " · ")
    }

    // MARK: - People here

    @ViewBuilder
    private var peoplePreview: some View {
        let others = (people.value?.attendees ?? []).filter { $0.relationship != .self }
        if others.isEmpty, people.value == nil, (rsvp.value?.count ?? 1) > 0 {
            // Holds the section's space while people load, so the rest of the page never
            // jumps down when they arrive.
            VStack(alignment: .leading, spacing: 12) {
                Text("People here")
                    .font(ClickTypography.sectionTitle)
                    .foregroundStyle(ClickColors.textPrimary)
                Text("Loading who's going").font(ClickTypography.supporting)
                HStack(spacing: 16) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(spacing: 6) {
                            Circle().fill(ClickColors.fillSubtle).frame(width: 60, height: 60)
                            Capsule().fill(ClickColors.fillSubtle).frame(width: 44, height: 10)
                        }
                        .frame(width: 66)
                    }
                }
            }
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
        } else if !others.isEmpty {
            let ranked = EventDirectoryView.bestMatch(others)
            let mutuals = others.filter { $0.relationship == .connection || $0.relationship == .mutual }.count
            VStack(alignment: .leading, spacing: 12) {
                Button { showingDirectory = true } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("People here")
                                .font(ClickTypography.sectionTitle)
                                .foregroundStyle(ClickColors.textPrimary)
                            Text([mutuals > 0 ? "\(mutuals) mutual\(mutuals == 1 ? "" : "s")" : nil, "\(rsvp.value?.count ?? others.count) going"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(ClickTypography.supporting)
                                .foregroundStyle(ClickColors.textSecondary)
                        }
                        Spacer()
                        Text("See all")
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(ClickColors.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(ranked.prefix(10)) { person in
                            NavigationLink(value: person.relationship == .connection
                ? AppRoute.userProfile(userID: person.userID, connectionID: nil)
                : AppRoute.publicProfile(userID: person.userID)) {
                                VStack(spacing: 6) {
                                    AvatarView(imageURL: person.avatarURL, seed: person.userID, initials: person.initials, size: 60)
                                    Text(person.name.split(separator: " ").first.map(String.init) ?? person.name)
                                        .font(ClickTypography.supporting)
                                        .foregroundStyle(ClickColors.textPrimary)
                                        .lineLimit(1)
                                }
                                .frame(width: 66)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Other beacon actions

    @ViewBuilder
    private func beaconActions(_ beacon: MapBeacon) -> some View {
        HStack(spacing: 0) {
            if beacon.kind == .soundtrack, let raw = beacon.musicURL, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true {
                iconAction("Open music", systemImage: "music.note") { UIApplication.shared.open(url) }
            }
            iconAction("Directions", systemImage: "location.north.line") { openDirections(beacon) }
            iconAction("Map", systemImage: "map") { env.router.showOnMap(.place(beacon.id)) }
        }
    }

    /// Only the destination leaves the app; the user's location is not sent.
    private func openDirections(_ beacon: MapBeacon) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: beacon.coordinate))
        item.name = beacon.locationName ?? beacon.title
        item.openInMaps()
    }

    // MARK: - Loading & writes

    /// Paints from the beacon cache instantly (chat card, map, Home), then refreshes. For an
    /// event whose kind is already known, RSVP/engagement/people load in parallel with it.
    private func load() async {
        let cached = await env.beacons.cachedBeacon(id: beaconID)
        if let cached {
            beacon.seed(cached.beacon)
            isExpired = cached.isExpired
        }
        beacon.begin()
        async let engagementTask: Void = cached?.beacon.isEvent == true ? loadEngagement() : ()
        if cached?.isFresh == true {
            beacon.succeedKeepingValue()
        } else {
            do {
                let result = try await env.beacons.beacon(id: beaconID)
                isExpired = result.isExpired
                beacon.succeed(result.beacon)
            } catch {
                beacon.fail(error)
            }
        }
        await engagementTask
        if cached?.beacon.isEvent != true, beacon.value?.isEvent == true { await loadEngagement() }
    }

    private func loadEngagement() async {
        if let cached = await env.events.cachedRSVP(beaconID: beaconID) { rsvp.seed(cached) }
        if let cached = await env.events.cachedEngagement(beaconID: beaconID) { engagement.seed(cached) }
        if let cached = await env.events.cachedDirectory(beaconID: beaconID) { people.seed(cached) }
        rsvp.begin()
        engagement.begin()
        async let rsvpTask = env.events.rsvpState(beaconID: beaconID)
        async let engagementTask = env.events.engagement(beaconID: beaconID)
        async let peopleTask = env.events.directory(beaconID: beaconID)
        do { rsvp.succeed(try await rsvpTask) } catch { rsvp.fail(error) }
        do { engagement.succeed(try await engagementTask) } catch { engagement.fail(error) }
        do { people.succeed(try await peopleTask) } catch { people.fail(error) }
    }

    private func setRSVP(_ beacon: MapBeacon) async {
        rsvpPending = true
        defer { rsvpPending = false }
        do {
            let request = try await env.events.rsvp(beaconID: beacon.id)
            rsvp.succeed(try await env.events.rsvpState(beaconID: beacon.id))
            switch request {
            case .pending?: notice = "Request sent. You'll be able to join once the host approves."
            case .waitlisted?: notice = "The event is full — you're on the waitlist."
            default: ClickHaptics.success()
            }
            await syncReminders(beacon)
        } catch {
            notice = error.userFacingMessage
        }
    }

    private func cancelRSVP(_ beacon: MapBeacon) async {
        rsvpPending = true
        defer { rsvpPending = false }
        do {
            try await env.events.cancelRSVP(beaconID: beacon.id)
            rsvp.succeed(try await env.events.rsvpState(beaconID: beacon.id))
            await syncReminders(beacon)
        } catch {
            notice = "Couldn't cancel. \(error.userFacingMessage)"
        }
    }

    /// Optimistic with rollback (spec §56.3).
    private func toggleBookmark(_ beacon: MapBeacon) async {
        guard var current = engagement.value else { return }
        let target = !current.bookmarked
        bookmarkPending = true
        current.bookmarked = target
        engagement.succeed(current)
        defer { bookmarkPending = false }
        do {
            current.bookmarked = try await env.events.setBookmark(beaconID: beacon.id, bookmarked: target)
            engagement.succeed(current)
            ClickHaptics.selection()
            await syncReminders(beacon)
        } catch {
            current.bookmarked = !target
            engagement.succeed(current)
            notice = "Couldn't update your saved events. \(error.userFacingMessage)"
        }
    }

    /// Reminders exist while the user is going or has saved the event (spec §59).
    private func syncReminders(_ beacon: MapBeacon) async {
        let interested = rsvp.value?.isGoing == true || engagement.value?.bookmarked == true
        guard interested, let schedule = beacon.schedule else {
            await EventReminderScheduler.cancel(beaconID: beacon.id)
            return
        }
        var enabled = true
        if let userID = env.session.currentSession?.userId,
           let preferences = try? await env.me.notificationPreferences(userID: userID) {
            enabled = preferences[.eventReminders]
        }
        await EventReminderScheduler.schedule(beaconID: beacon.id, title: beacon.title, start: schedule.start,
                                              place: beacon.locationName, enabled: enabled)
    }

    /// While a join request is pending, re-check every 30 s so the host's decision shows
    /// without leaving the screen (push/realtime also refresh it when available).
    private func watchPendingRequest() async {
        while !Task.isCancelled, rsvp.value?.request == .pending {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let fresh = try? await env.events.rsvpState(beaconID: beaconID) else { continue }
            if fresh != rsvp.value {
                rsvp.succeed(fresh)
                if fresh.request == .approved || fresh.isGoing {
                    notice = "You're in — the host approved your request."
                    ClickHaptics.success()
                } else if fresh.request == .denied {
                    notice = "The host couldn't approve your request this time."
                }
            }
        }
    }

    private func toggleCheckIn(_ beacon: MapBeacon) async {
        guard var current = engagement.value, !checkInPending else { return }
        checkInPending = true
        defer { checkInPending = false }
        do {
            if current.checkedIn {
                try await env.events.checkOut(beaconID: beacon.id)
                current.checkedIn = false
            } else {
                // Location is requested only for this action; the server owns the geofence.
                if env.permissions.status(for: .locationWhenInUse) == .notDetermined {
                    _ = await env.permissions.requestPermission(for: .locationWhenInUse)
                }
                let fix = await env.location.preciseLocation(targetAccuracy: 50, timeout: .seconds(8))
                current.checkInCount = try await env.events.checkIn(
                    beaconID: beacon.id,
                    latitude: fix?.coordinate.latitude,
                    longitude: fix?.coordinate.longitude,
                    accuracy: fix?.horizontalAccuracy
                )
                current.checkedIn = true
                ClickHaptics.success()
            }
            engagement.succeed(current)
        } catch {
            notice = error.localizedDescription
        }
    }

    private func delete(_ beacon: MapBeacon) async {
        do {
            try await env.events.deleteBeacon(id: beacon.id)
            await env.beacons.evict(id: beacon.id)
            env.router.noteBeaconDeleted(beacon.id)
            dismiss()
        } catch {
            notice = "Couldn't delete. \(error.userFacingMessage)"
        }
    }

    /// Legacy KMP beacons stored the literal label "Current location"; show a real place.
    nonisolated static func needsReverseGeocode(_ beacon: MapBeacon) -> Bool {
        let label = beacon.locationName?.trimmingCharacters(in: .whitespaces).lowercased()
        return label == nil || label == "current location"
    }

    nonisolated static func displayPlace(_ beacon: MapBeacon, resolved: (name: String?, address: String?)?) -> (title: String?, subtitle: String?) {
        if needsReverseGeocode(beacon) {
            let title = resolved?.name ?? beacon.formattedAddress
            return (title, resolved?.address ?? (resolved?.name != nil ? beacon.formattedAddress : nil))
        }
        return (beacon.locationName, beacon.formattedAddress)
    }

    /// Descriptions keep their inline formatting (links, emphasis) instead of raw markdown.
    nonisolated static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private extension Image {
    /// 44 pt glass circle used for controls floating over the hero image.
    func headerCircle(tint: Color) -> some View {
        self.font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
            .environment(\.colorScheme, .dark)
    }
}

/// Event people directory (spec §57). Default order is best match — shared interests plus
/// mutual connections, high to low — with A–Z, Interests, and Mutuals views. The server
/// decides which fields a viewer receives.
struct EventDirectoryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let beaconID: String
    var preloaded: EventDirectory?

    init(beaconID: String, preloaded: EventDirectory? = nil) {
        self.beaconID = beaconID
        self.preloaded = preloaded
        _directory = State(initialValue: ModuleState(value: preloaded, phase: preloaded != nil ? .loaded : .idle))
    }

    enum Sort: String, CaseIterable, Identifiable {
        case best = "Best match"
        case name = "A–Z"
        case interests = "Interests"
        case mutuals = "Mutuals"
        var id: String { rawValue }
    }

    @State private var directory: ModuleState<EventDirectory>
    @State private var sort: Sort = .best

    /// Shared interests + mutual connections (a direct Click counts as a strong mutual).
    nonisolated static func score(_ person: DirectoryAttendee) -> Int {
        person.sharedInterests.count + person.mutualCount + (person.relationship == .connection ? 3 : 0)
    }

    nonisolated static func bestMatch(_ people: [DirectoryAttendee]) -> [DirectoryAttendee] {
        people.sorted { (score($0), $1.name) > (score($1), $0.name) }
    }

    private var everyone: [DirectoryAttendee] {
        (directory.value?.attendees ?? []).filter { $0.relationship != .self }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .id("top")

                if directory.value != nil {
                    if everyone.isEmpty {
                        Text("No one else has RSVP'd yet.").foregroundStyle(ClickColors.textSecondary)
                    } else {
                        ForEach(sections, id: \.title) { section in
                            Section(section.title) { rows(section.people) }
                        }
                    }
                } else if let error = directory.errorMessage {
                    Button("Couldn't load people. Retry") { Task { await load() } }
                        .accessibilityHint(error)
                } else {
                    ClickLoadingView(size: 28, fillsSpace: false)
                }
            }
            .listStyle(.insetGrouped)
            .onChange(of: sort) { _, _ in withAnimation { proxy.scrollTo("top", anchor: .top) } }
        }
        // The event sheet has no navigation bar; this screen doesn't either, so pushing it
        // never toggles a bar mid-transition (which shifted the list down after it opened).
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .background { SwipeBackEnabler().frame(width: 0, height: 0) }
        .navigationTitle("People here")
        .task {
            if let preloaded, directory.value == nil { directory.succeed(preloaded) }
            await load()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ClickColors.textPrimary)
                    .frame(width: 44, height: 44)
                    .glassCircleBackground()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            VStack(alignment: .leading, spacing: 0) {
                Text("People here").font(ClickTypography.bodyEmphasized)
                Text(directory.value == nil ? " " : "\(everyone.count) going")
                    .font(ClickTypography.caption)
                    .foregroundStyle(ClickColors.textSecondary)
                    .contentTransition(.numericText())
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(height: 56)
        .background(ClickColors.background)
    }

    private var sections: [(title: String, people: [DirectoryAttendee])] {
        let byName = everyone.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        switch sort {
        case .best:
            return [("Best matches for you", Self.bestMatch(everyone))]
        case .name:
            return [("Everyone · A–Z", byName)]
        case .interests:
            let sharing = everyone.filter { !$0.sharedInterests.isEmpty }
                .sorted { ($0.sharedInterests.count, $1.name) > ($1.sharedInterests.count, $0.name) }
            let others = byName.filter { $0.sharedInterests.isEmpty }
            return [("Shares your interests", sharing), ("Others", others)].filter { !$0.people.isEmpty }
        case .mutuals:
            let known = everyone.filter { $0.relationship == .connection || $0.relationship == .mutual || $0.mutualCount > 0 }
                .sorted { ($0.mutualCount + ($0.relationship == .connection ? 100 : 0), $1.name) > ($1.mutualCount + ($1.relationship == .connection ? 100 : 0), $0.name) }
            let others = byName.filter { person in !known.contains(where: { $0.id == person.id }) }
            return [("Mutuals here · \(known.count)", known), ("Everyone", others)].filter { !$0.people.isEmpty }
        }
    }

    private func rows(_ people: [DirectoryAttendee]) -> some View {
        ForEach(people) { person in
            NavigationLink(value: AppRoute.userProfile(userID: person.userID, connectionID: nil)) {
                HStack(spacing: 12) {
                    AvatarView(imageURL: person.avatarURL, seed: person.userID, initials: person.initials, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(person.name)
                            .font(ClickTypography.bodyEmphasized)
                            .foregroundStyle(ClickColors.textPrimary)
                        ForEach(Self.details(person), id: \.self) { line in
                            Text(line)
                                .font(ClickTypography.supporting)
                                .foregroundStyle(ClickColors.textSecondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    if let badge = Self.badge(person) {
                        Text(badge)
                            .font(ClickTypography.metadataEmphasized)
                            .foregroundStyle(ClickColors.accentForeground)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(ClickColors.selectionTint, in: Capsule())
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    nonisolated static func badge(_ person: DirectoryAttendee) -> String? {
        switch person.relationship {
        case .connection: "Your Click"
        case .mutual: "Mutual"
        default: nil
        }
    }

    /// Everything the server shared, most useful first: mutual friends, shared interests, RSVP time.
    nonisolated static func details(_ person: DirectoryAttendee) -> [String] {
        var lines: [String] = []
        if person.mutualCount > 0 {
            let names = person.mutualNames.prefix(2).joined(separator: ", ")
            let count = "\(person.mutualCount) friend\(person.mutualCount == 1 ? "" : "s") in common"
            lines.append(names.isEmpty ? count : "\(count) · \(names)")
        }
        if !person.sharedInterests.isEmpty {
            lines.append("Into " + person.sharedInterests.prefix(3).joined(separator: ", ")
                         + (person.sharedInterests.count > 3 ? " +\(person.sharedInterests.count - 3)" : ""))
        }
        if lines.isEmpty {
            lines.append(person.signedUpAt.map { "Going · RSVP'd \($0.formatted(.relative(presentation: .named)))" } ?? "Going")
        }
        return lines
    }

    private func load() async {
        directory.begin()
        do {
            directory.succeed(try await env.events.directory(beaconID: beaconID))
        } catch {
            directory.fail(error)
        }
    }
}

/// "Share to chat": pick a Click or group, then send the event card (plaintext card fields).
struct ShareToChatSheet: View {
    @Environment(AppEnvironment.self) private var env
    let beacon: MapBeacon

    var body: some View {
        ChatTargetPicker(title: "Share to chat") { identity in
            guard let userID = env.session.currentSession?.userId else { return }
            _ = try await env.chat.sendBeacon(conversation: identity, currentUserID: userID, currentUserName: "You",
                                              beacon: beacon, clientMessageID: UUID().uuidString.lowercased())
        }
    }
}
