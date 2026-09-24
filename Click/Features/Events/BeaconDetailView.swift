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
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(beacon.value?.kind.label ?? "Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { if beacon.value == nil { await load() } }
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
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .clipped()

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

                    if beacon.creatorID == env.session.currentSession?.userId {
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .background(ClickColors.surface)
        .navigationDestination(isPresented: $showingDirectory) {
            EventDirectoryView(beaconID: beacon.id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: URL(string: "https://joinclick.co/e/\(beacon.id)")!, subject: Text(beacon.title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
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
        default: title = beacon.approvalRequired == true ? "Request to join" : "RSVP"; symbol = nil
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

    /// Event chat · Check in · Save · Directions — equal-width labelled icon actions.
    private func eventActionRow(_ beacon: MapBeacon) -> some View {
        let checkedIn = engagement.value?.checkedIn == true
        let saved = engagement.value?.bookmarked == true
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
            iconAction(saved ? "Saved" : "Save", systemImage: saved ? "bookmark.fill" : "bookmark", busy: bookmarkPending) {
                Task { await toggleBookmark(beacon) }
            }
            .disabled(engagement.value == nil || bookmarkPending)
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
                env.router.showOnMap(.beacon(beacon.id))
            } label: {
                infoRow(
                    systemImage: "mappin.and.ellipse",
                    title: beacon.locationName ?? beacon.formattedAddress ?? "Show on map",
                    subtitle: beacon.locationName != nil ? beacon.formattedAddress : nil,
                    chevron: true
                )
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

    // MARK: - Other beacon actions

    @ViewBuilder
    private func beaconActions(_ beacon: MapBeacon) -> some View {
        HStack(spacing: 0) {
            if beacon.kind == .soundtrack, let raw = beacon.musicURL, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true {
                iconAction("Open music", systemImage: "music.note") { UIApplication.shared.open(url) }
            }
            iconAction("Directions", systemImage: "location.north.line") { openDirections(beacon) }
            iconAction("Map", systemImage: "map") { env.router.showOnMap(.beacon(beacon.id)) }
        }
    }

    /// Only the destination leaves the app; the user's location is not sent.
    private func openDirections(_ beacon: MapBeacon) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: beacon.coordinate))
        item.name = beacon.locationName ?? beacon.title
        item.openInMaps()
    }

    // MARK: - Loading & writes

    private func load() async {
        beacon.begin()
        do {
            let result = try await env.beacons.beacon(id: beaconID)
            isExpired = result.isExpired
            beacon.succeed(result.beacon)
            if result.beacon.isEvent { await loadEngagement() }
        } catch {
            beacon.fail(error.userFacingMessage)
        }
    }

    private func loadEngagement() async {
        rsvp.begin()
        engagement.begin()
        async let rsvpTask = env.events.rsvpState(beaconID: beaconID)
        async let engagementTask = env.events.engagement(beaconID: beaconID)
        do { rsvp.succeed(try await rsvpTask) } catch { rsvp.fail(error.userFacingMessage) }
        do { engagement.succeed(try await engagementTask) } catch { engagement.fail(error.userFacingMessage) }
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
        } catch {
            notice = error.localizedDescription
        }
    }

    private func cancelRSVP(_ beacon: MapBeacon) async {
        rsvpPending = true
        defer { rsvpPending = false }
        do {
            try await env.events.cancelRSVP(beaconID: beacon.id)
            rsvp.succeed(try await env.events.rsvpState(beaconID: beacon.id))
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
        } catch {
            current.bookmarked = !target
            engagement.succeed(current)
            notice = "Couldn't update your saved events. \(error.userFacingMessage)"
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
            dismiss()
        } catch {
            notice = "Couldn't delete. \(error.userFacingMessage)"
        }
    }

    /// Descriptions keep their inline formatting (links, emphasis) instead of raw markdown.
    nonisolated static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Event people directory (spec §57): A–Z, Interests, Mutuals; the server decides fields.
struct EventDirectoryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let beaconID: String

    enum Sort: String, CaseIterable, Identifiable {
        case name = "A–Z"
        case interests = "Interests"
        case mutuals = "Mutuals"
        var id: String { rawValue }
    }

    @State private var directory = ModuleState<EventDirectory>()
    @State private var sort: Sort = .name

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .id("top")

                if let value = directory.value {
                    let people = value.attendees.filter { $0.relationship != .self }
                    if people.isEmpty {
                        Text("No one else has RSVP'd yet.")
                            .foregroundStyle(ClickColors.textSecondary)
                    } else if sort == .mutuals, value.mutualsUnlocked {
                        let known = people.filter { $0.relationship == .connection || $0.relationship == .mutual }
                            .sorted { $0.mutualCount > $1.mutualCount }
                        if !known.isEmpty {
                            Section("Mutuals here") { rows(known) }
                        }
                        Section("Everyone") { rows(people.filter { !known.contains($0) }.sorted { $0.name < $1.name }) }
                    } else {
                        Section { rows(sorted(people)) }
                    }
                } else if let error = directory.errorMessage {
                    Button("Couldn't load people. Retry") { Task { await load() } }
                        .accessibilityHint(error)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .onChange(of: sort) { _, _ in withAnimation { proxy.scrollTo("top", anchor: .top) } }
        }
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func sorted(_ people: [DirectoryAttendee]) -> [DirectoryAttendee] {
        switch sort {
        case .name, .mutuals: people.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .interests: people.sorted { ($0.sharedInterests.count, $1.name) > ($1.sharedInterests.count, $0.name) }
        }
    }

    private func rows(_ people: [DirectoryAttendee]) -> some View {
        ForEach(people) { person in
            // Pushes inside the event sheet's own stack (contract 3), not onto the tab.
            NavigationLink(value: AppRoute.userProfile(userID: person.userID, connectionID: nil)) {
                HStack(spacing: 12) {
                    AvatarView(imageURL: person.avatarURL, seed: person.userID, initials: person.initials, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name).foregroundStyle(ClickColors.textPrimary)
                        if let detail = detail(person) {
                            Text(detail)
                                .font(ClickTypography.metadata)
                                .foregroundStyle(ClickColors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func detail(_ person: DirectoryAttendee) -> String? {
        switch person.relationship {
        case .connection: return "Your Click"
        case .mutual:
            let names = person.mutualNames.prefix(2).joined(separator: ", ")
            return names.isEmpty ? "\(person.mutualCount) mutual" : "Via \(names)"
        default:
            return person.sharedInterests.isEmpty ? nil : "\(person.sharedInterests.count) shared interests"
        }
    }

    private func load() async {
        directory.begin()
        do {
            directory.succeed(try await env.events.directory(beaconID: beaconID))
        } catch {
            directory.fail(error.userFacingMessage)
        }
    }
}
