import MapKit
import SwiftUI

// MARK: - Together (profile section)

/// The friendship at a glance on a Click's profile: level and progress, streak, spots, the
/// map of where you've met, hangouts waiting for a confirmation, and what to do next.
/// Everything is derived from real encounters.
struct FriendshipSection: View {
    let peerName: String
    let avatarURL: String?
    let seed: String
    let encounters: [Encounter]
    let pendingHangouts: [PendingHangout]
    let onConfirm: (PendingHangout) -> Void
    let onDecline: (PendingHangout) -> Void
    let onLog: () -> Void
    let onPlan: () -> Void
    let onStory: () -> Void
    var upcomingPlans: [ChatMessageItem] = []
    var onOpenPlan: (ChatMessageItem) -> Void = { _ in }

    var body: some View {
        let stats = FriendshipStats.compute(encounters)
        VStack(alignment: .leading, spacing: 14) {
            header(stats)
            ForEach(pendingHangouts) { hangout in
                PendingHangoutRow(hangout: hangout, peerName: peerName,
                                  onConfirm: { onConfirm(hangout) }, onDecline: { onDecline(hangout) })
            }
            if !stats.isEmpty {
                statsRow(stats)
                let person = GroupMember(userID: seed, name: peerName, avatarURL: avatarURL)
                EncounterMapPreview(encounters: encounters, stats: stats) { _ in [person] }
            }
            UpcomingPlansList(plans: upcomingPlans, onOpen: onOpenPlan)
            HStack(spacing: 8) {
                pill("Log hangout", systemImage: "plus.circle", action: onLog)
                pill("Plan", systemImage: "calendar.badge.plus", action: onPlan)
                if stats.hangouts >= 2 {
                    pill("Your story", systemImage: "sparkles.rectangle.stack", action: onStory)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupedSurface()
    }

    @ViewBuilder
    private func header(_ stats: FriendshipStats) -> some View {
        if stats.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Together").font(ClickTypography.bodyEmphasized)
                Text("Log a hangout with \(peerName) to start your shared story.")
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textTertiary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label(stats.level.name, systemImage: stats.level.symbol)
                        .font(ClickTypography.bodyEmphasized)
                        .foregroundStyle(ClickColors.accentForeground)
                    Spacer()
                    if let first = stats.firstMet {
                        Text("Since \(first.date.formatted(.dateTime.month(.abbreviated).year()))")
                            .font(ClickTypography.metadata)
                            .foregroundStyle(ClickColors.textTertiary)
                    }
                }
                ProgressView(value: stats.levelProgress)
                    .tint(ClickColors.accentForeground)
                    .accessibilityLabel("Friendship level progress")
                Text(stats.nextLevel.map { "\(stats.toNextLevel) more \(stats.toNextLevel == 1 ? "hangout" : "hangouts") to \($0.name)" }
                     ?? "The highest level. You two are inseparable.")
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textSecondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func statsRow(_ stats: FriendshipStats) -> some View {
        HStack(spacing: 0) {
            stat("\(stats.hangouts)", stats.hangouts == 1 ? "hangout" : "hangouts")
            stat("\(stats.spots.count)", stats.spots.count == 1 ? "spot" : "spots")
            if stats.weekStreak >= 2 {
                stat("🔥 \(stats.weekStreak)", "week streak")
            } else if stats.neighborhoods > 1 {
                stat("\(stats.neighborhoods)", "neighborhoods")
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(ClickColors.textPrimary).monospacedDigit()
            Text(label).font(ClickTypography.caption).foregroundStyle(ClickColors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func pill(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(ClickTypography.supportingEmphasized)
                .foregroundStyle(ClickColors.accentForeground)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(ClickColors.selectionTint, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// "Maya logged a hangout at Café Allegro" with Confirm / Not us, or "Waiting for Maya".
private struct PendingHangoutRow: View {
    let hangout: PendingHangout
    let peerName: String
    let onConfirm: () -> Void
    let onDecline: () -> Void

    private var title: String {
        if hangout.confirmedByMe { return "Waiting for \(peerName) to confirm" }
        return hangout.source == .nearby ? "Hanging out with \(peerName)?" : "\(peerName) logged a hangout"
    }

    private var detail: String {
        [hangout.locationName, hangout.occurredAt.map { EncounterLabels.whenLine($0) }].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: hangout.confirmedByMe ? "hourglass" : "figure.2")
                .foregroundStyle(ClickColors.accentForeground)
                .frame(width: 32, height: 32)
                .background(ClickColors.selectionTint, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(ClickTypography.supportingEmphasized).foregroundStyle(ClickColors.textPrimary)
                if !detail.isEmpty {
                    Text(detail).font(ClickTypography.metadata).foregroundStyle(ClickColors.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !hangout.confirmedByMe {
                Button("Not us", action: onDecline)
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textTertiary)
                Button("Confirm", action: onConfirm)
                    .font(ClickTypography.supportingEmphasized)
                    .foregroundStyle(ClickColors.primaryActionForeground)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(ClickColors.primaryActionFill, in: Capsule())
            }
        }
        .padding(10)
        .background(ClickColors.fillSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Map collection

/// Every located encounter on a map, numbered in the order they happened (1 = where you first
/// clicked); the newest pin is marked NEW when it's a spot you hadn't met at before. The card
/// is a still preview; tapping opens it full screen.
struct EncounterMapPreview: View {
    let encounters: [Encounter]
    let stats: FriendshipStats
    /// Who a pin shows: the person, or the group members who were there.
    let faces: (Encounter) -> [GroupMember]
    @State private var isExpanded = false

    private var pins: [EncounterPin] {
        let highlights = HangoutHighlights.of(encounters)
        let ordered = encounters.sorted { $0.date < $1.date }
        return ordered.enumerated().compactMap { index, encounter in
            guard let lat = encounter.latitude, let lon = encounter.longitude,
                  (lat, lon) != (0, 0), abs(lat) <= 90, abs(lon) <= 180 else { return nil }
            let isNewest = index == ordered.count - 1
            return EncounterPin(number: index + 1, encounter: encounter,
                                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                isNewSpot: isNewest && highlights?.isNewSpot == true, faces: faces(encounter))
        }
    }

    var body: some View {
        let pins = pins
        if !pins.isEmpty {
            EncounterMap(pins: pins, interactive: false)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                // The preview map takes no touches; this layer opens the full one.
                .overlay { Color.clear.contentShape(Rectangle()).onTapGesture { isExpanded = true } }
                .overlay(alignment: .bottomLeading) {
                    Text(stats.spots.count == 1 ? "1 spot" : "\(stats.spots.count) spots")
                        .font(ClickTypography.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.thinMaterial, in: Capsule())
                        .padding(10)
                        .allowsHitTesting(false)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Map of \(pins.count) encounters at \(stats.spots.count) spots. Opens a larger map.")
                .accessibilityAction { isExpanded = true }
                .sheet(isPresented: $isExpanded) {
                    NavigationStack {
                        EncounterMap(pins: pins, interactive: true)
                            .ignoresSafeArea(edges: .bottom)
                            .navigationTitle("Where you've met")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) { Button("Done") { isExpanded = false } }
                            }
                    }
                }
        }
    }
}

private struct EncounterPin: Identifiable {
    let number: Int
    let encounter: Encounter
    let coordinate: CLLocationCoordinate2D
    let isNewSpot: Bool
    let faces: [GroupMember]
    var id: String { encounter.id }
}

/// The map itself: who you met at each spot (overlapping when several) with its number badge.
private struct EncounterMap: View {
    let pins: [EncounterPin]
    let interactive: Bool

    private static let pinSize: CGFloat = 34

    @ViewBuilder
    private func faces(_ members: [GroupMember]) -> some View {
        if members.count >= 2 {
            GroupAvatarView(avatarURL: nil, seed: members[0].userID, initials: members[0].initials, members: members, size: Self.pinSize)
        } else if let member = members.first {
            AvatarView(imageURL: member.avatarURL, seed: member.userID, initials: member.initials, size: Self.pinSize)
                .overlay(Circle().stroke(.white, lineWidth: 2))
        }
    }

    var body: some View {
        Map(initialPosition: .automatic, interactionModes: interactive ? .all : []) {
            ForEach(pins) { pin in
                Annotation(interactive ? (pin.encounter.placeName ?? "") : "", coordinate: pin.coordinate, anchor: .bottom) {
                    ZStack(alignment: .topTrailing) {
                        faces(pin.faces)
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        Text("\(pin.number)")
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(ClickColors.accentForeground, in: Capsule())
                            .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                            .offset(x: 6, y: -6)
                    }
                    .overlay(alignment: .bottom) {
                        if pin.isNewSpot {
                            Text("NEW")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange, in: Capsule())
                                .offset(y: 8)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Encounter \(pin.number)\(pin.isNewSpot ? ", new spot" : "")\(pin.encounter.placeName.map { ", \($0)" } ?? ""), \(EncounterLabels.whenLine(pin.encounter.date))")
                }
                .annotationTitles(interactive ? .automatic : .hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .allowsHitTesting(interactive)
    }
}

// MARK: - Log a hangout

/// Log a hangout you had without tapping; it joins your shared timeline once they confirm.
struct LogHangoutSheet: View {
    let peerName: String
    /// Returns true when it was sent.
    let onSubmit: (Date, CLLocationCoordinate2D?, String?) async -> Bool

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date.now
    @State private var usesLocation = true
    @State private var place: PlanPlace?
    @State private var search = PlaceSearch()
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    DatePicker("Time", selection: $date, in: Date.now.addingTimeInterval(-7 * 86_400)...Date.now)
                }
                Section {
                    if let place {
                        HStack {
                            Label(place.name, systemImage: "mappin.circle.fill")
                            Spacer()
                            Button("Change") { self.place = nil }.font(ClickTypography.supporting)
                        }
                    } else {
                        TextField("Place name (optional)", text: $search.query)
                            .autocorrectionDisabled()
                        ForEach(search.results) { result in
                            Button {
                                Task { place = await search.resolve(result) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title).foregroundStyle(ClickColors.textPrimary)
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle).font(ClickTypography.metadata).foregroundStyle(ClickColors.textTertiary)
                                    }
                                }
                            }
                        }
                        if env.location.isAuthorized {
                            Toggle("Use my current location", isOn: $usesLocation)
                        }
                    }
                } header: {
                    Text("Where")
                } footer: {
                    Text("\(peerName) gets a notification to confirm. It's added to your shared timeline and map once they do.")
                }
            }
            .navigationTitle("Log a hangout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await submit() } }
                    }
                }
            }
            .interactiveDismissDisabled(isSending)
            .task {
                search.region = env.location.lastFix.map {
                    MKCoordinateRegion(center: $0.coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func submit() async {
        isSending = true
        defer { isSending = false }
        var coordinate = place?.coordinate
        // Only a hangout happening now can use where you are now.
        if coordinate == nil, usesLocation, abs(date.timeIntervalSinceNow) < 3 * 3600,
           let fix = await env.location.currentLocation(maximumAge: 300, acceptableAccuracy: 200, timeout: .seconds(5)) {
            coordinate = fix.coordinate
        }
        let name = place?.name ?? search.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if await onSubmit(date, coordinate, name.isEmpty ? nil : name) { dismiss() }
    }
}

// MARK: - Souvenir (after a tap)

/// The instant keepsake after a tap: who, where, when, the weather, and what this hangout
/// added (a new spot, a level, a streak, a milestone). Shareable as an image.
struct SouvenirCard: View {
    let peerName: String
    let peerSeed: String
    let peerInitials: String
    let encounter: Encounter?
    let highlights: HangoutHighlights?
    let date: Date
    /// Live avatar in the app; the rendered (shared) image uses initials only.
    var avatarURL: String?

    private var headline: String {
        guard let ordinal = highlights?.ordinal, ordinal > 1 else { return "First Click" }
        return "Hangout #\(ordinal)"
    }

    private var badges: [(String, String)] {
        guard let highlights else { return [] }
        var list: [(String, String)] = []
        if let level = highlights.leveledUpTo { list.append((level.symbol, "Now \(level.name)")) }
        if highlights.isNewSpot { list.append(("mappin.and.ellipse", "New spot")) }
        if highlights.weekStreak >= 2 { list.append(("flame.fill", "\(highlights.weekStreak)-week streak")) }
        if highlights.isMilestone { list.append(("star.fill", "\(highlights.ordinal)th hangout")) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AvatarView(imageURL: avatarURL, seed: peerSeed, initials: peerInitials, size: 52)
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                    Text("with \(peerName)")
                        .font(ClickTypography.body)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let place = encounter?.placeName {
                    Label(place, systemImage: "mappin")
                }
                Label(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()), systemImage: "clock")
                if let temperature = encounter?.temperatureCelsius {
                    Label("\(Int(temperature.rounded()))°" + (encounter?.weatherCondition.map { " · \($0)" } ?? ""), systemImage: "cloud.sun")
                }
            }
            .font(ClickTypography.supporting)
            .foregroundStyle(.white.opacity(0.9))
            if !badges.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(badges, id: \.1) { symbol, text in
                        Label(text, systemImage: symbol)
                            .font(ClickTypography.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                }
            }
            Text("Click")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .background(
            LinearGradient(colors: SouvenirPalette.colors(seed: peerSeed), startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

/// A stable gradient per person, so each friendship's souvenirs look like a set.
enum SouvenirPalette {
    private static let pairs: [[Color]] = [
        [Color(hex: "#6D28D9"), Color(hex: "#DB2777")],
        [Color(hex: "#1D4ED8"), Color(hex: "#0EA5E9")],
        [Color(hex: "#047857"), Color(hex: "#65A30D")],
        [Color(hex: "#B45309"), Color(hex: "#DC2626")],
        [Color(hex: "#0F766E"), Color(hex: "#4F46E5")]
    ]

    static func colors(seed: String) -> [Color] {
        let hash = seed.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return pairs[Int(hash % UInt32(pairs.count))]
    }
}

/// A rendered card, ready for the share sheet.
struct ShareableImage: Identifiable {
    let id = UUID()
    let image: UIImage

    /// Renders on demand (initials instead of remote avatars, which wouldn't have loaded into
    /// the snapshot).
    @MainActor
    static func render<V: View>(_ view: V, width: CGFloat) -> ShareableImage? {
        let renderer = ImageRenderer(content: view.frame(width: width).padding(16).background(Color.black))
        renderer.scale = 3
        return renderer.uiImage.map { ShareableImage(image: $0) }
    }
}

// MARK: - Your story

/// A friendship recap, one card per page (first meeting, hangouts, top spot, rhythm,
/// weather), each shareable as an image.
struct FriendshipStorySheet: View {
    let peerName: String
    let peerSeed: String
    let peerInitials: String
    let encounters: [Encounter]
    let onPlan: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var sharing: ShareableImage?

    private struct StoryPage: Identifiable {
        let id: Int
        let eyebrow: String
        let headline: String
        let detail: String
        let symbol: String
    }

    private var pages: [StoryPage] {
        let stats = FriendshipStats.compute(encounters)
        var list: [StoryPage] = []
        if let first = stats.firstMet {
            list.append(StoryPage(id: list.count, eyebrow: "Where it started",
                                  headline: first.date.formatted(.dateTime.month(.wide).day().year()),
                                  detail: first.placeName.map { "You first Clicked at \($0)." } ?? "The day you first Clicked.",
                                  symbol: "sparkles"))
        }
        list.append(StoryPage(id: list.count, eyebrow: stats.level.name,
                              headline: "\(stats.hangouts) hangouts",
                              detail: "\(stats.spots.count) \(stats.spots.count == 1 ? "spot" : "spots")"
                                  + (stats.neighborhoods > 1 ? " across \(stats.neighborhoods) neighborhoods" : "") + ".",
                              symbol: stats.level.symbol))
        if let top = stats.topSpot, let name = top.name {
            list.append(StoryPage(id: list.count, eyebrow: "Your spot", headline: name,
                                  detail: "\(top.visits) times and counting.", symbol: "mappin.and.ellipse"))
        }
        if stats.longestWeekStreak >= 2 || stats.favoriteTime != nil {
            let streak = stats.longestWeekStreak >= 2 ? "Longest run: \(stats.longestWeekStreak) weeks in a row." : nil
            let time = stats.favoriteTime.map { "You're \($0.rawValue) people." }
            list.append(StoryPage(id: list.count, eyebrow: "Your rhythm", headline: time ?? "Week after week",
                                  detail: streak ?? "Most of your hangouts happen in the \(stats.favoriteTime?.rawValue ?? "day").",
                                  symbol: "calendar"))
        }
        if let cold = stats.coldest, let warm = stats.warmest, let low = cold.temperatureCelsius, let high = warm.temperatureCelsius, high - low >= 5 {
            list.append(StoryPage(id: list.count, eyebrow: "Rain or shine",
                                  headline: "\(Int(low.rounded()))° to \(Int(high.rounded()))°",
                                  detail: "From \(cold.placeName ?? "a chilly day") to \(warm.placeName ?? "a warm one").",
                                  symbol: "thermometer.sun"))
        }
        return list
    }

    var body: some View {
        let pages = pages
        NavigationStack {
            VStack(spacing: 16) {
                TabView(selection: $page) {
                    ForEach(pages) { item in
                        // Room below the card for the page dots, so they never cover it.
                        card(item)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 44)
                            .frame(maxHeight: .infinity, alignment: .center)
                            .tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                HStack(spacing: 10) {
                    Button {
                        if let current = pages.first(where: { $0.id == page }) ?? pages.first {
                            sharing = ShareableImage.render(card(current), width: 340)
                        }
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.clickSecondary)
                    Button {
                        dismiss()
                        onPlan()
                    } label: {
                        Label("Plan next", systemImage: "calendar.badge.plus")
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.clickPrimary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .sheet(item: $sharing) { ActivityShareSheet(items: [$0.image]).presentationDetents([.medium, .large]) }
            .navigationTitle("You & \(peerName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func card(_ item: StoryPage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: item.symbol).font(.title2.weight(.semibold))
                Spacer()
                AvatarView(imageURL: nil, seed: peerSeed, initials: peerInitials, size: 36)
            }
            Spacer(minLength: 0)
            Text(item.eyebrow.uppercased())
                .font(ClickTypography.caption.weight(.bold))
                .opacity(0.8)
            Text(item.headline)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(3)
            Text(item.detail)
                .font(ClickTypography.body)
                .opacity(0.9)
            Text("Click · you & \(peerName)")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .opacity(0.65)
                .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // A fixed story shape: the same card on screen and in the shared image.
        .aspectRatio(4 / 5, contentMode: .fit)
        .background(
            LinearGradient(colors: SouvenirPalette.colors(seed: peerSeed + "\(item.id)"), startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Coming up (plans)

/// Plans in a chat that haven't happened yet; tapping one opens it in the chat.
struct UpcomingPlansList: View {
    let plans: [ChatMessageItem]
    let onOpen: (ChatMessageItem) -> Void

    var body: some View {
        ForEach(plans.prefix(3)) { message in
            if let plan = message.plan {
                Button { onOpen(message) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar")
                            .foregroundStyle(ClickColors.accentForeground)
                            .frame(width: 32, height: 32)
                            .background(ClickColors.selectionTint, in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(plan.title).font(ClickTypography.supportingEmphasized).foregroundStyle(ClickColors.textPrimary)
                            Text(PlanCardView.whenText(plan.startsAt, until: plan.endsAt) + (plan.placeName.map { " · \($0)" } ?? ""))
                                .font(ClickTypography.metadata)
                                .foregroundStyle(ClickColors.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        let going = message.reactions.first { $0.reactionType == HangoutPlan.goingReaction }?.count ?? 0
                        if going > 0 {
                            Text("\(going) going").font(ClickTypography.caption).foregroundStyle(ClickColors.textSecondary)
                        }
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(ClickColors.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the plan in the chat")
            }
        }
    }
}

// MARK: - Group together

/// A group's shared life, not a copy of the one-to-one view: how often you're together as a
/// group (you with two or more members at once), who shows up most, where you meet, and
/// what's coming up. Built from your own encounters with the members.
struct GroupTogetherSection: View {
    let group: CliqueItem
    let model: GroupSpaceModel
    let currentUserID: String?
    let onPlan: () -> Void
    let onOpenPlan: (ChatMessageItem) -> Void

    private var representatives: [Encounter] { model.hangouts.map(\.representative) }

    /// The members who were there, for a hangout's map pin.
    private func hangoutMembers(_ encounter: Encounter) -> [GroupMember] {
        guard let ids = model.hangouts.first(where: { $0.representative.id == encounter.id })?.memberIDs else { return [] }
        return group.members.filter { ids.contains($0.userID) }
    }

    /// Members you've been with most in group hangouts.
    private var regulars: [String] {
        var counts: [String: Int] = [:]
        for hangout in model.hangouts { for id in hangout.memberIDs { counts[id, default: 0] += 1 } }
        let names = Dictionary(group.members.map { ($0.userID, HomeFeedModel.firstName($0.name) ?? $0.name) }, uniquingKeysWith: { a, _ in a })
        return counts.sorted { $0.value > $1.value }.prefix(3).compactMap { names[$0.key] }
    }

    var body: some View {
        GroupedSection("Together") {
            if model.hangouts.isEmpty {
                Text("No group hangouts yet. Tap phones with two or more members at once and it shows up here.")
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textTertiary)
            } else {
                let stats = FriendshipStats.compute(representatives)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(stats.level.name, systemImage: stats.level.symbol)
                            .font(ClickTypography.bodyEmphasized)
                            .foregroundStyle(ClickColors.accentForeground)
                        Spacer()
                        Text("\(stats.hangouts) group \(stats.hangouts == 1 ? "hangout" : "hangouts") · \(stats.spots.count) \(stats.spots.count == 1 ? "spot" : "spots")")
                            .font(ClickTypography.metadata)
                            .foregroundStyle(ClickColors.textTertiary)
                    }
                    if !regulars.isEmpty {
                        Text("Most often with \(ListFormatter.localizedString(byJoining: regulars))")
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textSecondary)
                    }
                    if stats.weekStreak >= 2 {
                        Label("\(stats.weekStreak)-week streak", systemImage: "flame.fill")
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textSecondary)
                    }
                    EncounterMapPreview(encounters: representatives, stats: stats, faces: hangoutMembers)
                }
                .padding(.vertical, 4)
            }
            UpcomingPlansList(plans: model.upcomingPlans, onOpen: onOpenPlan)
            Button(action: onPlan) {
                Label(model.upcomingPlans.isEmpty ? "Plan something" : "Plan another", systemImage: "calendar.badge.plus")
            }
        }
    }
}
