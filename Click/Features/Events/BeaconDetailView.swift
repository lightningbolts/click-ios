import MapKit
import SwiftUI

/// The canonical beacon/event detail (spec §55–57), used by every entry point (Home, Saved,
/// Map, deep links, profiles). Actions depend on kind; every engagement write is confirmed by
/// the server before the UI reports it.
struct BeaconDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let beaconID: String
    /// From the route (`.event` vs `.beacon`), so the bar's buttons exist from the first frame.
    var isEvent = false
    /// Root of a detail sheet (closes it) rather than pushed onto a stack (goes back).
    var isSheetRoot = false

    @State private var beacon = ModuleState<MapBeacon>()
    @State private var isExpired = false
    @State private var rsvp = ModuleState<RSVPState>()
    @State private var engagement = ModuleState<EventEngagement>()
    @State private var rsvpPending = false
    @State private var bookmarkPending = false
    /// The latest local answer (optimistic toggle, then the server's confirmation).
    @State private var savedOverride: Bool?
    /// Loaded once per screen (coming back from People or a profile doesn't reload).
    @State private var hasLoaded = false
    /// Scrolled past the hero: the bar shows the title (like a profile's compact name).
    @State private var showsCompactTitle = false
    /// Where the large title ends, down the page's scroll content: once scrolled past, the bar shows it.
    @State private var titleBottom: CGFloat = .infinity
    @State private var checkInPending = false
    @State private var notice: String?
    /// Album art resolved on device for a soundtrack the server couldn't enrich.
    @State private var resolvedArtwork: String?
    @State private var confirmCancelRSVP = false
    @State private var confirmDelete = false
    @State private var people = ModuleState<EventDirectory>()
    @State private var sharingToChat = false
    @State private var editingBeacon = false
    /// Readable place for legacy beacons saved with the label "Current location".
    @State private var resolvedPlace: (name: String?, address: String?)?
    @State private var reporting = false

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
        .onDisappear { SoundtrackPreviewPlayer.shared.stop() }
        // The system bar, never a hidden one: every screen in the stack keeps a bar, so pushing
        // People or a profile never toggles it and shifts the content. It's clear over the hero
        // and takes the system background once the page scrolls past it (`heroBar`).
        .navigationTitle(beacon.value?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { headerButtons }
        // What this session already knows paints before the first frame; the network refreshes it.
        .onAppear(perform: seedFromCache)
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await load()
        }
        .task(id: rsvp.value?.request) { await watchPendingRequest() }
        .confirmationDialog("Report this?", isPresented: $reporting, titleVisibility: .visible) {
            ForEach(["Not accurate anymore", "Inappropriate", "Spam"], id: \.self) { reason in
                Button(reason) { Task { await report(reason) } }
            }
        } message: {
            Text("Reports go quietly to the Click team. Nobody else sees them.")
        }
        .alert("Event", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: - Content

    private nonisolated static let page = "eventPage"

    private func content(_ beacon: MapBeacon) -> some View {
        // Read here so the scroll threshold below updates once the title is measured.
        let pastTitleAt = titleBottom
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Inset and whole, at the picture's own shape (a poster is never cropped to a
                // banner); the uploaded image overrides the generated pattern.
                EventHero(seed: beacon.id, imageURL: beacon.imageURL ?? resolvedArtwork, symbol: beacon.kind.systemImage)
                    .id(beacon.imageURL ?? resolvedArtwork)

                VStack(alignment: .leading, spacing: 10) {
                    pills(beacon)
                    Text(beacon.title)
                        .font(ClickTypography.identityTitle)
                        .foregroundStyle(ClickColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(Self.page)).maxY }) { titleBottom = $0 }
                    hostLine(beacon)
                    if let schedule = beacon.schedule { whenLine(schedule) }
                    if isExpired {
                        Label("This has ended.", systemImage: "clock.badge.xmark")
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textSecondary)
                    }
                }

                if beacon.isEvent {
                    VStack(spacing: 10) {
                        if beacon.rsvpEnabled != false, !isExpired { rsvpButton(beacon) }
                        eventActionRow(beacon)
                    }
                    LocationNudgeCard(
                        nudge: .businessInsights,
                        systemImage: "chart.bar.xaxis",
                        title: "Help this venue host better events",
                        message: "Clicks you make here join the venue's anonymous count of how many people actually meet at its events. Venues use it to bring back the events where people connect, so you get more of them. Click never shares who you are or who you met.",
                        acceptTitle: "Count me in",
                        isRelevant: engagement.value?.checkedIn == true
                    )
                } else {
                    beaconActions(beacon)
                }

                if beacon.kind == .hazard, !isExpired, env.features.isEnabled(.alertConfirmations) {
                    AlertConfirmationSection(beacon: beacon) {
                        withAnimation(ClickMotion.content) { isExpired = true }
                    }
                }

                if beacon.kind == .soundtrack {
                    SoundtrackBeaconSection(beacon: beacon) { art in
                        withAnimation(ClickMotion.subtleFade) { resolvedArtwork = art }
                    }
                    if !isExpired, env.features.isEnabled(.soundtrackPresence) {
                        ListeningNowSection(beacon: beacon)
                    }
                }

                locationSection(beacon)

                if beacon.isEvent { peopleSection(beacon) }

                if let description = beacon.description, !description.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("About")
                        Text(Self.markdown(description))
                            .font(ClickTypography.body)
                            .foregroundStyle(ClickColors.textSecondary)
                            .tint(ClickColors.accentForeground)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .detailCard()
                    }
                }

                if beacon.isEvent, env.features.isEnabled(.eventDrops) {
                    EventDropsSection(beacon: beacon)
                }

                if beacon.creatorID == env.session.currentSession?.userId {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("Hosting")
                        VStack(spacing: 0) {
                            if beacon.isEvent {
                                NavigationLink(value: AppRoute.guestList(beaconID: beacon.id)) {
                                    infoRow(systemImage: "list.bullet.rectangle", title: "Guest list", subtitle: nil, chevron: true)
                                }
                                Divider().padding(.leading, 56)
                            }
                            Button { editingBeacon = true } label: {
                                infoRow(systemImage: "pencil", title: beacon.isEvent ? "Edit event" : "Edit beacon", subtitle: nil)
                            }
                            Divider().padding(.leading, 56)
                            Button { confirmDelete = true } label: {
                                infoRow(systemImage: "trash", title: beacon.isEvent ? "Delete event" : "Delete beacon",
                                        subtitle: nil, tint: ClickColors.destructive)
                            }
                        }
                        .buttonStyle(.plain)
                        .detailCard()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .coordinateSpace(.named(Self.page))
        }
        .heroBar(clear: !showsCompactTitle)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > pastTitleAt
        } action: { _, pastTitle in
            withAnimation(ClickMotion.subtleFade) { showsCompactTitle = pastTitle }
        }
        // The event's own colors wash the top of the page, under the bar and around the hero.
        .background {
            // Keyed by picture, so a new one (edited, or resolved art) washes in its own colors.
            EventBackdrop(seed: beacon.id, imageURL: beacon.imageURL ?? resolvedArtwork)
                .id(beacon.imageURL ?? resolvedArtwork)
                .ignoresSafeArea()
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
        .confirmation(rsvp.value?.isGoing == true ? "Cancel your RSVP?" : "Withdraw your request?", isPresented: $confirmCancelRSVP,
                      keep: rsvp.value?.isGoing == true ? "Keep RSVP" : "Keep Request") {
            Button(rsvp.value?.isGoing == true ? "Cancel RSVP" : "Withdraw request", role: .destructive) {
                Task { await cancelRSVP(beacon) }
            }
        }
        .confirmation("Delete \(beacon.title)?", isPresented: $confirmDelete, keep: "Keep It",
                      message: "It will be removed for everyone.") {
            Button("Delete", role: .destructive) { Task { await delete(beacon) } }
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

    /// Close (or Back, when pushed) · Save · Share over the hero (prototype event sheet header).
    @ToolbarContentBuilder
    private var headerButtons: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // Hidden over the hero (the page shows it large); fades in once scrolled past.
            Text(beacon.value?.title ?? "")
                .font(.headline)
                .lineLimit(1)
                .opacity(showsCompactTitle ? 1 : 0)
        }
        // Present from the first frame (disabled until loaded), so iOS morphs them in with the
        // push like any other bar buttons instead of popping them in once the beacon arrives.
        ToolbarItemGroup(placement: .topBarTrailing) {
            // Never disabled while loading (a dimmed icon brightening is its own pop-in): Save
            // starts from your saved events and Share only needs the link.
            if beacon.value?.isEvent ?? isEvent {
                let saved = isSaved
                Button {
                    if let beacon = beacon.value { Task { await toggleBookmark(beacon) } }
                } label: {
                    Label(saved ? "Remove from saved" : "Save event", systemImage: saved ? "bookmark.fill" : "bookmark")
                        .contentTransition(.symbolEffect(.replace))
                }
                .tint(saved ? ClickColors.accentForeground : nil)
            }
            Menu {
                Button("Copy link", systemImage: "link") {
                    UIPasteboard.general.string = shareURL.absoluteString
                    ClickHaptics.success()
                }
                if beacon.value != nil {
                    Button("Share to chat", systemImage: "bubble.left") { sharingToChat = true }
                }
                Button("View on Map", systemImage: "map") { env.router.showOnMap(.place(beaconID)) }
                ShareLink(item: shareURL, subject: Text(beacon.value?.title ?? "Click")) {
                    Label("More…", systemImage: "square.and.arrow.up")
                }
                if env.features.isEnabled(.alertConfirmations), let beacon = beacon.value,
                   beacon.creatorID != env.session.currentSession?.userId {
                    Button("Report", systemImage: "flag") { reporting = true }
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        // Close sits where Back does when pushed, so the bar has the same shape either way and
        // the title stays centered.
        if isSheetRoot {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
            }
        }
    }

    /// Event chat · Check in · Directions — equal-width labelled icon actions.
    private func eventActionRow(_ beacon: MapBeacon) -> some View {
        let checkedIn = engagement.value?.checkedIn == true
        let canCheckIn = !isExpired && (rsvp.value?.isGoing == true || beacon.schedule?.isLive() == true || checkedIn)
        return HStack(spacing: 10) {
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
            VStack(spacing: 6) {
                ZStack {
                    if busy { ProgressView() } else {
                        Image(systemName: systemImage).font(.system(size: 20, weight: .medium))
                    }
                }
                .frame(height: 24)
                Text(title)
                    .font(ClickTypography.supportingEmphasized)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint ?? ClickColors.textPrimary)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 68)
            // Filled tiles; a tinted state (checked in) tints its tile too.
            .background(tint?.opacity(0.16) ?? ClickColors.fillSubtle,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - When · where · who

    /// "Tomorrow · 12:00 – 1:30 PM", then how it sits: "Starts in 14 hours · You're free then".
    private func whenLine(_ schedule: EventSchedule) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(EventFormatting.when(schedule))
                .font(.title3)
                .foregroundStyle(ClickColors.textSecondary)
            if let subtitle = whenSubtitle(schedule) {
                Text(subtitle)
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .task { await env.calendar.refresh() }
    }

    /// The place, its address and a map of it, all opening it on Click's map; then the Click
    /// Place hosting it, when there is one.
    private func locationSection(_ beacon: MapBeacon) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Location")
            Button {
                env.router.showOnMap(.place(beacon.id))
            } label: {
                let label = Self.displayPlace(beacon, resolved: resolvedPlace)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label.title ?? "Show on map")
                                .font(ClickTypography.bodyEmphasized)
                                .foregroundStyle(ClickColors.textPrimary)
                            if let subtitle = label.subtitle {
                                Text(subtitle)
                                    .font(ClickTypography.supporting)
                                    .foregroundStyle(ClickColors.textSecondary)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(ClickColors.textTertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    EventMapPreview(coordinate: beacon.coordinate, title: label.title ?? beacon.title)
                }
                .detailCard()
                .contentShape(RoundedRectangle(cornerRadius: ClickRadius.surface, style: .continuous))
                .task(id: beacon.id) {
                    guard Self.needsReverseGeocode(beacon), resolvedPlace == nil else { return }
                    resolvedPlace = await PlaceSearchModel.reverseGeocode(beacon.coordinate)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows it on the map.")
            if let place = Self.placeLink(for: beacon, placesEnabled: env.features.isEnabled(.clickPlaces)) {
                NavigationLink(value: AppRoute.place(idOrSlug: place.id, anchorToken: nil)) {
                    infoRow(systemImage: "building.2", title: "At \(place.name)", subtitle: nil, chevron: true)
                }
                .buttonStyle(.plain)
                .detailCard()
            }
        }
    }

    /// Every section on the page titles the same way (About, People here, Hosting).
    private func sectionHeader(_ title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(ClickTypography.sectionTitle)
                .foregroundStyle(ClickColors.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
            }
        }
    }

    private func infoRow(systemImage: String, title: String, subtitle: String?, chevron: Bool = false,
                         tint: Color = ClickColors.textPrimary) -> some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ClickTypography.body)
                    .foregroundStyle(tint)
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

    /// "Starts in 2 days · You're free then": an upcoming event says how it sits on your calendar
    /// (read on this iPhone only) once you've allowed access.
    private func whenSubtitle(_ schedule: EventSchedule) -> String? {
        let relative = relativeTime(schedule)
        guard schedule.start > .now, let fit = env.calendar.fit(DateInterval(start: schedule.start, end: schedule.end)) else { return relative }
        return [relative, fit.text].compactMap { $0 }.joined(separator: " · ")
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

    private func peopleSubtitle(_ beacon: MapBeacon, mutuals: Int) -> String? {
        var parts: [String] = []
        if let here = engagement.value?.checkInCount, here > 0 { parts.append("\(here) here now") }
        if mutuals > 0 { parts.append("\(mutuals) mutual\(mutuals == 1 ? "" : "s")") }
        if let scale = beacon.venueScale?.nonEmptyTrimmed { parts.append(scale.prefix(1).uppercased() + scale.dropFirst()) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - People

    /// "48 going": a few faces and names (your Clicks and best matches first) and how many more,
    /// opening everyone. While they load, a placeholder holds the section's space.
    @ViewBuilder
    private func peopleSection(_ beacon: MapBeacon) -> some View {
        let others = EventDirectoryView.bestMatch((people.value?.attendees ?? []).filter { $0.relationship != .self })
        let loading = others.isEmpty && people.value == nil && (rsvp.value?.count ?? 1) > 0
        let mutuals = others.filter { $0.relationship == .connection || $0.relationship == .mutual }.count
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(peopleTitle(beacon), subtitle: peopleSubtitle(beacon, mutuals: mutuals))
            NavigationLink(value: AppRoute.eventPeople(beaconID: beacon.id)) {
                HStack(spacing: 12) {
                    if loading {
                        VStack(alignment: .leading, spacing: 10) {
                            Facepile(people: [], placeholders: 4, more: 0)
                            Capsule().fill(ClickColors.fillStrong).frame(width: 180, height: 12)
                        }
                        .accessibilityHidden(true)
                    } else {
                        let shown = Array(others.prefix(Self.facesShown))
                        // Everyone going but you: the server may send fewer people than it counts.
                        let total = max(others.count, (rsvp.value?.count ?? 0) - (rsvp.value?.isGoing == true ? 1 : 0))
                        let more = total - shown.count
                        VStack(alignment: .leading, spacing: 10) {
                            if !shown.isEmpty { Facepile(people: shown, placeholders: 0, more: more) }
                            Text(Self.goingNames(shown.map(\.name), more: more, isGoing: rsvp.value?.isGoing == true))
                                .font(ClickTypography.supporting)
                                .foregroundStyle(ClickColors.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ClickColors.textTertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .detailCard()
                .contentShape(RoundedRectangle(cornerRadius: ClickRadius.surface, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows everyone going.")
        }
    }

    private static let facesShown = 4

    /// "Andrew Lu, Pranav Donapaty, Zakia and 44 more"; "Just you so far" before anyone else.
    nonisolated static func goingNames(_ names: [String], more: Int, isGoing: Bool) -> String {
        guard !names.isEmpty else {
            if more > 0 { return "\(more) going" }
            return isGoing ? "Just you so far" : "See who's going"
        }
        guard more > 0 else { return ListFormatter.localizedString(byJoining: names) }
        return names.joined(separator: ", ") + " and \(more) more"
    }

    // MARK: - Other beacon actions

    @ViewBuilder
    private func beaconActions(_ beacon: MapBeacon) -> some View {
        HStack(spacing: 10) {
            if beacon.kind == .soundtrack, let raw = beacon.musicURL, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true {
                iconAction("Open music", systemImage: "music.note") { UIApplication.shared.open(url) }
            }
            iconAction("Directions", systemImage: "location.north.line") { openDirections(beacon) }
            iconAction("Map", systemImage: "map") { env.router.showOnMap(.place(beacon.id)) }
        }
    }

    private func report(_ reason: String) async {
        do {
            try await env.beacons.report(beaconID: beaconID, reason: reason)
            ClickHaptics.success()
            notice = "Thanks. The Click team will take a look."
        } catch {
            if !error.isCancellation { notice = "Couldn't send the report. \(error.userFacingMessage)" }
        }
    }

    /// Only the destination leaves the app; the user's location is not sent.
    private func openDirections(_ beacon: MapBeacon) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: beacon.coordinate))
        item.name = beacon.locationName ?? beacon.title
        item.openInMaps()
    }

    // MARK: - Loading & writes

    /// Seeds the beacon and, for an event, its RSVP, saved state and people from memory
    /// (discovery, chat cards, earlier opens), synchronously so the first frame has them.
    private func seedFromCache() {
        // RSVP state persists across launches (only events have one), so it seeds even when the
        // beacon itself still has to load.
        seedEngagement()
        guard beacon.value == nil, let cached = env.beacons.cachedBeacon(id: beaconID) else { return }
        beacon.seed(cached.beacon)
        isExpired = cached.isExpired
        env.beaconExtras.prefetch(cached.beacon, env: env)
    }

    private func seedEngagement() {
        if let cached = env.events.cachedRSVP(beaconID: beaconID) { rsvp.seed(cached) }
        if let cached = env.events.cachedEngagement(beaconID: beaconID) { engagement.seed(cached) }
        if let cached = env.events.cachedDirectory(beaconID: beaconID) { people.seed(cached) }
    }

    /// Refreshes what `seedFromCache` painted. For an event whose kind is already known,
    /// RSVP/engagement/people load in parallel with it.
    private func load() async {
        seedFromCache()
        let cached = env.beacons.cachedBeacon(id: beaconID)
        beacon.begin()
        async let engagementTask: Void = cached?.beacon.isEvent == true ? loadEngagement() : ()
        if cached?.isFresh == true {
            beacon.succeedKeepingValue()
        } else {
            do {
                let result = try await env.beacons.beacon(id: beaconID)
                isExpired = result.isExpired
                beacon.succeed(result.beacon)
                env.beaconExtras.prefetch(result.beacon, env: env)
            } catch {
                beacon.fail(error)
            }
        }
        await engagementTask
        if cached?.beacon.isEvent != true, beacon.value?.isEvent == true { await loadEngagement() }
    }

    private func loadEngagement() async {
        seedEngagement()
        rsvp.begin()
        engagement.begin()
        async let rsvpTask = env.events.rsvpState(beaconID: beaconID)
        async let engagementTask = env.events.engagement(beaconID: beaconID)
        async let peopleTask = env.events.directory(beaconID: beaconID)
        do { rsvp.succeed(try await rsvpTask) } catch { rsvp.fail(error) }
        do { engagement.succeed(try await engagementTask) } catch { engagement.fail(error) }
        do { people.succeed(try await peopleTask) } catch { people.fail(error) }
        // Ready the event chat for those who can open it, so it pushes straight in.
        if rsvp.value?.isGoing == true || beacon.value?.creatorID == env.session.currentSession?.userId {
            await EventChatView.prefetch(beaconID: beaconID, env: env)
        }
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

    private var shareURL: URL { URL(string: "https://joinclick.co/e/\(beaconID)")! }

    /// Saved state for the bar: your latest toggle, else the server's answer, else your saved
    /// events (already in memory), so a saved event shows saved from the first frame.
    private var isSaved: Bool {
        savedOverride ?? engagement.value?.bookmarked
            ?? env.selfData.savedEvents.value?.contains { $0.beaconID == beaconID } ?? false
    }

    /// Optimistic with rollback (spec §56.3).
    private func toggleBookmark(_ beacon: MapBeacon) async {
        guard !bookmarkPending else { return }
        let target = !isSaved
        bookmarkPending = true
        savedOverride = target
        defer { bookmarkPending = false }
        do {
            savedOverride = try await env.events.setBookmark(beaconID: beacon.id, bookmarked: target)
            ClickHaptics.selection()
            await syncReminders(beacon)
            await env.selfData.loadSavedEvents(force: true)
        } catch {
            savedOverride = !target
            notice = "Couldn't update your saved events. \(error.userFacingMessage)"
        }
    }

    /// Reminders exist while the user is going or has saved the event (spec §59).
    private func syncReminders(_ beacon: MapBeacon) async {
        let interested = rsvp.value?.isGoing == true || isSaved
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

    /// The listed Click Place hosting this event, shown as "At {place}" only with Places on (spec 6.9).
    nonisolated static func placeLink(for beacon: MapBeacon, placesEnabled: Bool) -> MapBeaconPlace? {
        placesEnabled ? beacon.place : nil
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

private extension View {
    /// The page starts under the bar (full-bleed hero), so the system would shade the bar over
    /// the photo. Clear keeps the photo crisp there; past the hero the bar gets its background.
    func heroBar(clear: Bool) -> some View {
        toolbarBackground(clear ? .hidden : .automatic, for: .navigationBar)
            .scrollEdgeEffectHiddenIfAvailable(clear, for: .top)
    }
}

extension View {
    /// The event page's one card style (info, Click Drops, people, hosting).
    func detailCard() -> some View {
        background(ClickColors.fillSubtle, in: RoundedRectangle(cornerRadius: ClickRadius.surface, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: ClickRadius.surface, style: .continuous))
    }
}

/// The event's picture, inset and rounded at its own shape (between 4:5 and 2:1), so a poster
/// shows whole instead of cropped to a banner; the generated visual is a 16:9 banner. A picture
/// already decoded sets the shape on the first frame.
private struct EventHero: View {
    let seed: String
    let imageURL: String?
    let symbol: String

    @State private var aspect: CGFloat

    init(seed: String, imageURL: String?, symbol: String) {
        self.seed = seed
        self.imageURL = imageURL
        self.symbol = symbol
        _aspect = State(initialValue: Self.url(imageURL)
            .flatMap { ImagePipeline.shared.firstFrameImage(for: $0, maxPixelSize: EventVisual.pixelSize) }
            .map(Self.aspect) ?? Self.bannerAspect)
    }

    private static let bannerAspect: CGFloat = 16 / 9

    private static func url(_ raw: String?) -> URL? { raw?.nonEmptyTrimmed.flatMap(URL.init(string:)) }

    private static func aspect(_ image: UIImage) -> CGFloat {
        guard image.size.height > 0 else { return bannerAspect }
        return min(max(image.size.width / image.size.height, 0.8), 2)
    }

    var body: some View {
        EventVisual(seed: seed, imageURL: imageURL, symbol: symbol, cornerRadius: ClickRadius.prominent)
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .task(id: imageURL) {
                guard let url = Self.url(imageURL),
                      let image = await ImagePipeline.shared.image(for: url, maxPixelSize: EventVisual.pixelSize) else { return }
                let fitted = Self.aspect(image)
                if abs(fitted - aspect) > 0.01 { withAnimation(ClickMotion.content) { aspect = fitted } }
            }
    }
}

/// A wash of the event's own colors over the top of its page, fading into the page: its picture
/// shrunk to a few pixels and stretched (a blur that costs nothing to draw), else its generated
/// gradient.
private struct EventBackdrop: View {
    let seed: String
    let imageURL: String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var swatch: UIImage?

    private static let swatchSize: CGFloat = 12

    init(seed: String, imageURL: String?) {
        self.seed = seed
        self.imageURL = imageURL
        _swatch = State(initialValue: Self.url(imageURL).flatMap {
            ImagePipeline.shared.firstFrameImage(for: $0, maxPixelSize: Self.swatchSize)
        })
    }

    private static func url(_ raw: String?) -> URL? { raw?.nonEmptyTrimmed.flatMap(URL.init(string:)) }

    var body: some View {
        ZStack(alignment: .top) {
            ClickColors.surface
            Group {
                if let swatch {
                    Image(uiImage: swatch)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else {
                    LinearGradient(colors: CardVisual(seed: seed).gradient.map(Color.init(hex:)),
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 560)
            .clipped()
            .opacity(colorScheme == .dark ? 0.5 : 0.35)
            .mask(LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: imageURL) {
            guard swatch == nil, let url = Self.url(imageURL) else { return }
            let loaded = await ImagePipeline.shared.image(for: url, maxPixelSize: Self.swatchSize)
            if let loaded { withAnimation(ClickMotion.subtleFade) { swatch = loaded } }
        }
    }
}

/// A still map of the place with its pin; the card around it opens the real map.
private struct EventMapPreview: View {
    let coordinate: CLLocationCoordinate2D
    let title: String

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1200, longitudinalMeters: 1200)),
            interactionModes: []) {
            Marker(title, coordinate: coordinate)
                .tint(ClickColors.primaryActionFill)
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .id("\(coordinate.latitude),\(coordinate.longitude)")
        .frame(height: 150)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A few overlapping faces and how many more; empty circles while people load.
private struct Facepile: View {
    let people: [DirectoryAttendee]
    let placeholders: Int
    let more: Int

    private static let size: CGFloat = 36

    var body: some View {
        HStack(spacing: -10) {
            ForEach(people) { person in
                AvatarView(imageURL: person.avatarURL, seed: person.userID, initials: person.initials, size: Self.size)
                    .ringed()
            }
            ForEach(0..<placeholders, id: \.self) { _ in
                Circle().fill(ClickColors.fillStrong).frame(width: Self.size, height: Self.size).ringed()
            }
            if more > 0 {
                Text("+\(more)")
                    .font(ClickTypography.metadataEmphasized)
                    .foregroundStyle(ClickColors.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(minWidth: Self.size, minHeight: Self.size)
                    .background(ClickColors.surfaceElevated, in: Capsule())
                    .ringed()
            }
        }
        .accessibilityHidden(true)
    }
}

private extension View {
    /// The page's color around a face, so overlapping faces read apart.
    func ringed() -> some View {
        padding(2).background(ClickColors.surface, in: Capsule())
    }
}

/// Event people directory (spec §57). Default order is best match — shared interests plus
/// mutual connections, high to low — with A–Z, Interests, and Mutuals views. The server
/// decides which fields a viewer receives.
struct EventDirectoryView: View {
    @Environment(AppEnvironment.self) private var env
    let beaconID: String

    enum Sort: String, CaseIterable, Identifiable {
        case best = "Best match"
        case name = "A–Z"
        case interests = "Interests"
        case mutuals = "Mutuals"
        var id: String { rawValue }
    }

    @State private var directory = ModuleState<EventDirectory>()
    @State private var sort: Sort = .best

    /// Shared interests + mutual connections (a direct Click counts as a strong mutual).
    nonisolated static func score(_ person: DirectoryAttendee) -> Int {
        person.sharedInterests.count + person.mutualCount + (person.relationship == .connection ? 3 : 0)
    }

    nonisolated static func bestMatch(_ people: [DirectoryAttendee]) -> [DirectoryAttendee] {
        people.sorted { (score($0), $1.name) > (score($1), $0.name) }
    }

    /// Everyone but you (sorted and sectioned); you're pinned above them.
    private var everyone: [DirectoryAttendee] {
        (directory.value?.attendees ?? []).filter { $0.relationship != .self }
    }

    private var me: DirectoryAttendee? {
        directory.value?.attendees.first { $0.relationship == .self }
    }

    private var hasEnded: Bool { directory.value?.hasEnded ?? false }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Color.clear.frame(height: 0)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .id("top")

                if let current = directory.value {
                    if current.attendees.isEmpty {
                        Text(hasEnded ? "No one RSVP'd to this one." : "No one has RSVP'd yet.").foregroundStyle(ClickColors.textSecondary)
                    } else {
                        if let me {
                            Section { rows([me]) }
                        }
                        if everyone.isEmpty {
                            Text(hasEnded ? "No one else RSVP'd." : "No one else has RSVP'd yet.")
                                .foregroundStyle(ClickColors.textSecondary)
                                .listRowBackground(ClickColors.surfaceElevated)
                        } else {
                            ForEach(sections, id: \.title) { section in
                                Section(section.title) { rows(section.people) }
                            }
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
            .listSectionSpacing(.compact)
            .contentMargins(.top, 4, for: .scrollContent)
            // Opaque like the event sheet it's pushed from (the sheet's glass showed through
            // at the medium height while the header stayed solid).
            .scrollContentBackground(.hidden)
            .background(ClickColors.surface.ignoresSafeArea())
            .onChange(of: sort) { _, _ in withAnimation { proxy.scrollTo("top", anchor: .top) } }
        }
        // The system bar, like the event before it and the profiles after it: the bar never
        // toggles mid-stack, so nothing shifts as screens push.
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(title).font(ClickTypography.bodyEmphasized)
                    // Everyone, you included: the same count as the event's "N going".
                    Text(directory.value.map { "\($0.attendees.count) \(hasEnded ? "went" : "going")" } ?? " ")
                        .font(ClickTypography.caption)
                        .foregroundStyle(ClickColors.textSecondary)
                        .contentTransition(.numericText())
                }
            }
        }
        // The event detail already cached who's going: paint that on the first frame, then refresh.
        .onAppear {
            if directory.value == nil, let cached = env.events.cachedDirectory(beaconID: beaconID) { directory.seed(cached) }
        }
        .task { await load() }
    }

    private var title: String { hasEnded ? "Who was there" : "People here" }

    /// Sort control, pinned above the list.
    private var header: some View {
        Picker("Sort", selection: $sort) {
            ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(ClickColors.surface)
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
            Group {
                // Your own row is a marker, not a door to your own profile.
                if person.relationship == .self {
                    row(person)
                } else {
                    NavigationLink(value: AppRoute.userProfile(userID: person.userID, connectionID: nil)) { row(person) }
                }
            }
            .listRowBackground(ClickColors.surfaceElevated)
        }
    }

    private func row(_ person: DirectoryAttendee) -> some View {
                HStack(spacing: 12) {
                    AvatarView(imageURL: person.avatarURL, seed: person.userID, initials: person.initials, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        // The badge sits beside the name so the detail lines get the full width.
                        HStack(spacing: 6) {
                            Text(person.name)
                                .font(ClickTypography.bodyEmphasized)
                                .foregroundStyle(ClickColors.textPrimary)
                                .lineLimit(1)
                            if let badge = Self.badge(person) {
                                Text(badge)
                                    .font(ClickTypography.caption.weight(.semibold))
                                    .foregroundStyle(ClickColors.accentForeground)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(ClickColors.selectionTint, in: Capsule())
                                    .fixedSize()
                            }
                        }
                        ForEach(Self.details(person, ended: hasEnded), id: \.self) { line in
                            Text(line)
                                .font(ClickTypography.supporting)
                                .foregroundStyle(ClickColors.textSecondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
    }

    nonisolated static func badge(_ person: DirectoryAttendee) -> String? {
        switch person.relationship {
        case .self: "You"
        case .connection: "Your Click"
        case .mutual: "Mutual"
        default: nil
        }
    }

    /// Everything the server shared, most useful first: mutual friends, shared interests, RSVP time.
    nonisolated static func details(_ person: DirectoryAttendee, ended: Bool = false) -> [String] {
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
            if ended {
                lines.append(person.signedUpAt.map { "RSVP'd \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? "Went")
            } else {
                lines.append(person.signedUpAt.map { "Going · RSVP'd \($0.formatted(.relative(presentation: .named)))" } ?? "Going")
            }
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
        ChatTargetPicker(title: "Share to chat", preview: beacon.title, previewSymbol: "calendar") { identity in
            guard let userID = env.session.currentSession?.userId else { return }
            _ = try await env.chat.sendBeacon(conversation: identity, currentUserID: userID, currentUserName: "You",
                                              beacon: beacon, clientMessageID: UUID().uuidString.lowercased())
        }
    }
}
