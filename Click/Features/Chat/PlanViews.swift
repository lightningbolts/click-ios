import MapKit
import SwiftUI

// MARK: - Planner

/// "Plan a hangout": what, when, where (search, or a place you've met before), then send to
/// the chat as a plan card people answer with Going / Can't.
struct PlanHangoutSheet: View {
    /// Who it's with ("Maya", or the group's name).
    let withName: String
    /// Direct chats: the pair's connection, for "Places you've met".
    var connectionID: String?
    let onSend: (HangoutPlan) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    private var settings: SettingsStore { env.settings }
    @State private var title = ""
    @State private var startsAt = PlanHangoutSheet.defaultStart()
    @State private var hasEnd = false
    @State private var endsAt = PlanHangoutSheet.defaultStart().addingTimeInterval(2 * 3600)
    @State private var isAddingIdea = false
    @State private var newIdea = ""
    @State private var place: PlanPlace?
    @State private var search = PlaceSearch()
    @State private var metSpots: [FriendshipSpot] = []
    @FocusState private var placeFocused: Bool

    private static let ideas = ["☕️ Coffee", "🍜 Dinner", "🍻 Drinks", "🚶 Walk", "🎬 Movie", "🏋️ Workout"]

    /// 7 PM today, or tomorrow once it's late in the day.
    static func defaultStart(now: Date = .now, calendar: Calendar = .current) -> Date {
        let todayEvening = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: now) ?? now
        if todayEvening.timeIntervalSince(now) > 2 * 3600 { return todayEvening }
        return calendar.date(byAdding: .day, value: 1, to: todayEvening) ?? todayEvening
    }

    /// Today (while there's evening left) and the next six days; picking one keeps the time.
    private var weekDays: [(label: String, day: Date)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<7).compactMap { offset -> (String, Date)? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let label = switch offset {
            case 0: "Today"
            case 1: "Tomorrow"
            default: day.formatted(.dateTime.weekday(.abbreviated).day())
            }
            return (label, day)
        }
    }

    /// Moves the plan to `day`, keeping its time of day (and its length, if it has an end).
    private func move(to day: Date) {
        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute], from: startsAt)
        guard let moved = calendar.date(bySettingHour: time.hour ?? 19, minute: time.minute ?? 0, second: 0, of: day) else { return }
        let length = endsAt.timeIntervalSince(startsAt)
        startsAt = moved
        endsAt = moved.addingTimeInterval(max(1800, length))
    }

    private var ideas: [String] { settings.planIdeas + Self.ideas.filter { !settings.planIdeas.contains($0) } }

    private var canSend: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && startsAt > .now && (!hasEnd || endsAt > startsAt)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What") {
                    TextField("Coffee, dinner, a walk…", text: $title)
                        .submitLabel(.next)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(ideas, id: \.self) { idea in
                                chip(idea, selected: title == idea) { title = idea }
                                    .contextMenu {
                                        if settings.planIdeas.contains(idea) {
                                            Button("Remove", systemImage: "trash", role: .destructive) {
                                                settings.planIdeas.removeAll { $0 == idea }
                                            }
                                        }
                                    }
                            }
                            chip("＋ Add your own", selected: false) {
                                newIdea = title.trimmingCharacters(in: .whitespacesAndNewlines)
                                isAddingIdea = true
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                Section("When") {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(weekDays, id: \.day) { item in
                                chip(item.label, selected: Calendar.current.isDate(startsAt, inSameDayAs: item.day)) { move(to: item.day) }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    DatePicker("Starts", selection: $startsAt, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    Toggle("End time", isOn: $hasEnd.animation(ClickMotion.content))
                    if hasEnd {
                        DatePicker("Ends", selection: $endsAt, in: startsAt.addingTimeInterval(900)..., displayedComponents: [.date, .hourAndMinute])
                    }
                }
                .onChange(of: startsAt) { old, new in
                    // Keep the length when the start moves; never end before it starts.
                    endsAt = new.addingTimeInterval(max(1800, endsAt.timeIntervalSince(old)))
                }

                Section {
                    if let place {
                        HStack {
                            Label(place.name, systemImage: "mappin.circle.fill")
                                .foregroundStyle(ClickColors.textPrimary)
                            Spacer()
                            Button("Change") { self.place = nil; placeFocused = true }
                                .font(ClickTypography.supporting)
                        }
                    } else {
                        TextField("Search places", text: $search.query)
                            .focused($placeFocused)
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
                        if search.query.isEmpty, !metSpots.isEmpty {
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    ForEach(metSpots.prefix(8)) { spot in
                                        if let name = spot.name {
                                            chip("📍 \(name)", selected: false) {
                                                place = PlanPlace(name: name, coordinate: spot.coordinate)
                                            }
                                        }
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                    }
                } header: {
                    Text("Where")
                } footer: {
                    if place == nil, search.query.isEmpty, !metSpots.isEmpty {
                        Text("Places you and \(withName) have met.")
                    } else {
                        Text("Optional.")
                    }
                }
            }
            .alert("New idea", isPresented: $isAddingIdea) {
                TextField("🎮 Game night", text: $newIdea)
                Button("Cancel", role: .cancel) { newIdea = "" }
                Button("Add") {
                    let idea = String(newIdea.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                    guard !idea.isEmpty else { return }
                    settings.planIdeas = [idea] + settings.planIdeas.filter { $0 != idea }
                    title = idea
                    newIdea = ""
                }
            } message: {
                Text("Saved on this iPhone for your next plans. Long-press it to remove.")
            }
            .navigationTitle("Plan with \(withName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSend(HangoutPlan(title: String(trimmed.prefix(80)), startsAt: startsAt, endsAt: hasEnd ? endsAt : nil,
                                           placeName: place?.name,
                                           latitude: place?.coordinate?.latitude, longitude: place?.coordinate?.longitude))
                        ClickHaptics.success()
                        dismiss()
                    }
                    .disabled(!canSend)
                }
            }
            .task {
                search.region = env.location.lastFix.map {
                    MKCoordinateRegion(center: $0.coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
                }
                guard let connectionID, let encounters = try? await env.profiles.encounters(connectionID: connectionID) else { return }
                metSpots = FriendshipStats.compute(encounters).spots
                    .filter { $0.name != nil }
                    .sorted { $0.visits > $1.visits }
            }
        }
        .presentationDetents([.large])
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { ClickHaptics.selection(); action() }) {
            Text(label)
                .font(ClickTypography.supporting.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? ClickColors.accentForeground : ClickColors.textPrimary)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(selected ? ClickColors.selectionTint : ClickColors.fillSubtle, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct PlanPlace: Equatable {
    let name: String
    let coordinate: CLLocationCoordinate2D?

    static func == (a: PlanPlace, b: PlanPlace) -> Bool {
        a.name == b.name && a.coordinate?.latitude == b.coordinate?.latitude && a.coordinate?.longitude == b.coordinate?.longitude
    }
}

/// MapKit place autocomplete, biased to where you are.
@MainActor
@Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    struct Result: Identifiable, Sendable {
        let id: Int
        let title: String
        let subtitle: String
    }

    var query = "" {
        didSet {
            if query.isEmpty { results = [] } else { completer.queryFragment = query }
        }
    }
    private(set) var results: [Result] = []
    var region: MKCoordinateRegion? {
        didSet { if let region { completer.region = region } }
    }

    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var completions: [MKLocalSearchCompletion] = []

    override init() {
        super.init()
        completer.resultTypes = [.pointOfInterest, .address]
        completer.delegate = self
    }

    // MapKit calls its delegate on the main thread.
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { refreshResults() }
    }

    private func refreshResults() {
        completions = Array(completer.results.prefix(6))
        results = completions.enumerated().map { Result(id: $0.offset, title: $0.element.title, subtitle: $0.element.subtitle) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { results = [] }
    }

    /// The place (name + coordinate) for a suggestion; falls back to its title alone.
    func resolve(_ result: Result) async -> PlanPlace {
        guard completions.indices.contains(result.id) else { return PlanPlace(name: result.title, coordinate: nil) }
        let item = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completions[result.id])).start().mapItems.first
        return PlanPlace(name: item?.name ?? result.title, coordinate: item?.placemark.coordinate)
    }
}

// MARK: - Plan card (in chat)

/// A plan in the timeline: what, when, where, and Going / Can't (reactions under the hood).
struct PlanCardView: View {
    let plan: HangoutPlan
    let message: ChatMessageItem
    let onRSVP: ((Bool) -> Void)?
    /// Who answered (the reactors sheet for ✅ or ❌).
    var onShowResponses: ((String) -> Void)? = nil

    @Environment(\.openURL) private var openURL

    private func count(_ reaction: String) -> Int {
        message.reactions.first { $0.reactionType == reaction }?.count ?? 0
    }

    private func mine(_ reaction: String) -> Bool {
        message.reactions.first { $0.reactionType == reaction }?.userReacted ?? false
    }

    /// Plans stay answerable until they end (or three hours after they start).
    private var isOver: Bool { plan.endsOrAssumedEnd < .now }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Plan", systemImage: "calendar")
                .font(ClickTypography.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(ClickColors.accentForeground)
            Text(plan.title)
                .font(ClickTypography.bodyEmphasized)
                .foregroundStyle(ClickColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Label(Self.whenText(plan.startsAt, until: plan.endsAt), systemImage: "clock")
                .font(ClickTypography.supporting)
                .foregroundStyle(ClickColors.textSecondary)
            if let placeName = plan.placeName {
                Button {
                    openURL(Self.mapsURL(plan: plan, placeName: placeName))
                } label: {
                    Label(placeName, systemImage: "mappin.and.ellipse")
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.accentForeground)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens in Maps")
            }
            Divider()
            if isOver {
                Text(count(HangoutPlan.goingReaction) > 0 ? "\(count(HangoutPlan.goingReaction)) went" : "This plan has passed")
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textTertiary)
            } else {
                HStack(spacing: 8) {
                    rsvpButton("Going", systemImage: "checkmark", reaction: HangoutPlan.goingReaction, going: true)
                    rsvpButton("Can't", systemImage: "xmark", reaction: HangoutPlan.declinedReaction, going: false)
                }
                let going = count(HangoutPlan.goingReaction)
                let declined = count(HangoutPlan.declinedReaction)
                if going + declined > 0 {
                    Button {
                        onShowResponses?(going > 0 ? HangoutPlan.goingReaction : HangoutPlan.declinedReaction)
                    } label: {
                        HStack(spacing: 4) {
                            Text([going > 0 ? "\(going) going" : nil, declined > 0 ? "\(declined) can't" : nil].compactMap { $0 }.joined(separator: " · "))
                            if onShowResponses != nil { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)) }
                        }
                        .font(ClickTypography.metadata)
                        .foregroundStyle(ClickColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(onShowResponses == nil)
                    .accessibilityHint("Shows who's going")
                }
            }
            HStack {
                Spacer()
                Text(message.formattedTime)
                    .font(ClickTypography.caption)
                    .foregroundStyle(ClickColors.textTertiary)
                    .monospacedDigit()
            }
        }
        .padding(14)
        .frame(width: 264, alignment: .leading)
        .background(ClickColors.surface, in: RoundedRectangle(cornerRadius: ClickRadius.messageBubble, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ClickRadius.messageBubble, style: .continuous)
            .stroke(ClickColors.separator, lineWidth: ClickMetrics.strokeWidth))
        .accessibilityElement(children: .contain)
    }

    private func rsvpButton(_ title: String, systemImage: String, reaction: String, going: Bool) -> some View {
        let selected = mine(reaction)
        return Button {
            ClickHaptics.selection()
            onRSVP?(going)
        } label: {
            Label(title, systemImage: systemImage)
                .font(ClickTypography.supportingEmphasized)
                .foregroundStyle(selected ? ClickColors.primaryActionForeground : ClickColors.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(selected ? ClickColors.primaryActionFill : ClickColors.fillSubtle, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(onRSVP == nil || message.deliveryStatus == .sending || message.deliveryStatus == .failed)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func whenText(_ date: Date, until end: Date? = nil, now: Date = .now, calendar: Calendar = .current) -> String {
        var time = date.formatted(date: .omitted, time: .shortened)
        if let end {
            time += "–" + (calendar.isDate(end, inSameDayAs: date)
                ? end.formatted(date: .omitted, time: .shortened)
                : end.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        }
        if calendar.isDateInToday(date) { return "Today · \(time)" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow · \(time)" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day,
           (0..<7).contains(days) {
            return "\(date.formatted(.dateTime.weekday(.wide))) · \(time)"
        }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(time)"
    }

    static func mapsURL(plan: HangoutPlan, placeName: String) -> URL {
        var parts = URLComponents(string: "https://maps.apple.com/")!
        var items = [URLQueryItem(name: "q", value: placeName)]
        if let lat = plan.latitude, let lon = plan.longitude { items.append(URLQueryItem(name: "ll", value: "\(lat),\(lon)")) }
        parts.queryItems = items
        return parts.url!
    }
}

// MARK: - Group revival

/// Shown at the top of a group chat that has gone quiet for three weeks.
struct GroupRevivalBanner: View {
    let quietDays: Int
    let onPlan: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .foregroundStyle(ClickColors.accentForeground)
                .frame(width: 36, height: 36)
                .background(ClickColors.selectionTint, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("It's been quiet")
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
                Text("\(max(3, quietDays / 7)) weeks since the last message. Plan something?")
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textSecondary)
            }
            Spacer(minLength: 6)
            Button("Plan", action: onPlan)
                .font(ClickTypography.supportingEmphasized)
                .foregroundStyle(ClickColors.accentForeground)
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
                .background(ClickColors.selectionTint, in: Capsule())
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ClickColors.textTertiary)
                    .frame(width: 28, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .glassPanelBackground(cornerRadius: 22)
    }
}
