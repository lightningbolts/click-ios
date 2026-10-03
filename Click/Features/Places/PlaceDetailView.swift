import CoreLocation
import SwiftUI

/// A Click Place page (spec §6.4): Now, Your visit (check-in + Pulse), Happening here, Your
/// Clicks, Your history, Community, About. Every surface is hidden unless Places is on.
struct PlaceDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let idOrSlug: String
    let anchorToken: String?

    var body: some View {
        if env.features.isEnabled(.clickPlaces) {
            PlaceDetailContent(model: PlaceDetailModel(
                idOrSlug: idOrSlug,
                anchorToken: anchorToken,
                repository: env.places,
                source: anchorToken == nil ? "link" : "qr",
                locate: { [env] in await PlaceDetailView.locateOnce(env) }
            ))
        } else {
            ContentUnavailableView("Not available", systemImage: "mappin.slash")
        }
    }

    /// One foreground fix for this tap, like event check-in (no monitoring, nothing stored).
    @MainActor
    static func locateOnce(_ env: AppEnvironment) async -> PlaceLocationOutcome {
        if env.permissions.status(for: .locationWhenInUse) == .notDetermined {
            _ = await env.permissions.requestPermission(for: .locationWhenInUse)
        }
        switch env.permissions.status(for: .locationWhenInUse) {
        case .denied, .restricted: return .denied
        default: break
        }
        guard let fix = await env.location.preciseLocation(targetAccuracy: 30, timeout: .seconds(8)) else { return .unavailable }
        return .fix(fix.coordinate, accuracy: fix.horizontalAccuracy)
    }
}

private struct PlaceDetailContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State var model: PlaceDetailModel
    @State private var showingMetHere = false

    var body: some View {
        Group {
            switch model.loadState {
            case .failed(let message) where model.detail == nil:
                ContentUnavailableView(message, systemImage: "mappin.slash")
            default:
                if let detail = model.detail {
                    content(detail)
                } else {
                    ClickLoadingView()
                }
            }
        }
        .task { await model.load() }
        // Refresh while checked in and visible: a foreground timer only, no background work.
        .task(id: model.isCheckedIn && scenePhase == .active) {
            guard model.isCheckedIn, scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await model.load()
            }
        }
        .confirmationDialog(
            "Check in at \(model.detail?.summary.name ?? "this Place")?",
            isPresented: Binding(get: { model.showAnchorConfirmation && model.detail != nil }, set: { if !$0 { model.dismissAnchorConfirmation() } }),
            titleVisibility: .visible
        ) {
            Button("Check in") { Task { await model.confirmAnchorCheckIn() } }
            Button("Not now", role: .cancel) { model.dismissAnchorConfirmation() }
        }
        .sheet(isPresented: $showingMetHere) {
            if let met = model.detail?.youMetHere { MetHereSheet(people: met.people) }
        }
    }

    @ViewBuilder
    private func content(_ detail: PlaceDetail) -> some View {
        List {
            header(detail)
            nowSection(detail)
            visitSection(detail)
            if !detail.upcomingEvents.isEmpty { eventsSection(detail) }
            clicksSection(detail)
            historySection(detail)
            if let hub = detail.hub { communitySection(hub) }
            aboutSection(detail)
            if detail.isManager {
                Section {
                    Link("You manage this Place. Edit it on joinclick.co/business.", destination: URL(string: "https://joinclick.co/business/places")!)
                        .font(ClickTypography.supporting)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.load() }
        .navigationTitle(detail.summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Never includes an anchor token.
                ShareLink(item: URL(string: "https://joinclick.co/p/\(detail.summary.slug)")!) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    // MARK: - Sections

    private func header(_ detail: PlaceDetail) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                EventVisual(seed: detail.id, imageURL: detail.summary.photoURL?.absoluteString, symbol: detail.summary.category.symbol, cornerRadius: 14)
                    .aspectRatio(16 / 9, contentMode: .fit)
                Text(detail.summary.name)
                    .font(.title2.bold())
                    .foregroundStyle(ClickColors.textPrimary)
                Text([detail.summary.category.label, detail.summary.city].compactMap { $0 }.joined(separator: " · "))
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
                if let hours = detail.todayHoursLabel {
                    HStack(spacing: 6) {
                        Text(hours).font(ClickTypography.supporting)
                        if let open = detail.summary.openNow {
                            StatusPill(open ? "Open" : "Closed", style: open ? .tinted : .neutral)
                        }
                    }
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private func nowSection(_ detail: PlaceDetail) -> some View {
        let pulse = detail.summary.pulse
        return Section("Now") {
            switch (pulse.state, pulse.label) {
            case (.live, let label?):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(label.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(label.color, in: Capsule())
                        Text(PlaceCopy.liveDetail(pulse)).font(ClickTypography.supporting)
                        if let chip = PlaceCopy.confidence(pulse.confidence) {
                            StatusPill(chip, style: .neutral)
                        }
                    }
                    EnergyBars(distribution: pulse.distribution)
                    if let counts = pulse.categoryCounts, let question = pulse.categoryQuestion {
                        Text(PlaceDetailContent.categoryLine(question, counts: counts)).font(ClickTypography.supporting)
                    }
                    if pulse.talkableYes + pulse.talkableNo > 0 {
                        Text("Easy to talk: \(pulse.talkableYes) yes · \(pulse.talkableNo) no").font(ClickTypography.supporting)
                    }
                }
            default:
                Text(PlaceCopy.pulseLine(pulse)).font(ClickTypography.body)
            }
            if let pattern = detail.pattern {
                Text(PlaceCopy.pattern(pattern))
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
            }
            if let hereNow = PlaceCopy.hereNow(detail.summary.hereNowCount) {
                Text(hereNow).font(ClickTypography.bodyEmphasized)
            }
            if !detail.hereNowConnections.isEmpty {
                HStack(spacing: 8) {
                    HStack(spacing: -8) {
                        ForEach(detail.hereNowConnections.prefix(4)) { person in
                            AvatarView(imageURL: person.avatarURL?.absoluteString, seed: person.userID, initials: String(person.name.prefix(1)), size: 28)
                        }
                    }
                    Text("\(PlaceCopy.names(detail.hereNowConnections.map(\.name), total: detail.hereNowConnections.count)) \(detail.hereNowConnections.count == 1 ? "is" : "are") here")
                        .font(ClickTypography.supporting)
                }
            }
        }
    }

    @ViewBuilder
    private func visitSection(_ detail: PlaceDetail) -> some View {
        Section("Your visit") {
            if let checkIn = detail.checkIn, checkIn.active {
                HStack {
                    Text(checkIn.expiresAt.map { "Checked in · until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Checked in")
                        .font(ClickTypography.bodyEmphasized)
                    Spacer()
                    Button("Leave") { Task { await model.checkOut() } }
                        .buttonStyle(.bordered)
                }
            } else {
                Toggle("Let my Clicks see I'm here", isOn: $model.shareWithConnections)
                Button {
                    Task { await model.checkIn() }
                } label: {
                    HStack {
                        Spacer()
                        if model.checkInPhase == .locating || model.checkInPhase == .submitting {
                            ProgressView()
                        } else {
                            Text("I'm here").font(ClickTypography.bodyEmphasized)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.checkInPhase == .locating || model.checkInPhase == .submitting)
            }
            if case .failed(let error) = model.checkInPhase {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error.message)
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.destructive)
                    HStack {
                        Button("Try again") { Task { await model.checkIn() } }
                        if error == .noLocation {
                            Button("Settings") { env.permissions.openSystemSettings() }
                        }
                    }
                    .font(ClickTypography.supportingEmphasized)
                }
            }
            if model.showWouldReturn, let question = model.wouldReturnQuestion {
                WouldReturnCard(question: question) { value in Task { await model.answerWouldReturn(value) } }
            }
            if model.showsPulseCard { PulseCard(model: model) }
        }
    }

    private func eventsSection(_ detail: PlaceDetail) -> some View {
        Section("Happening here") {
            ForEach(detail.upcomingEvents) { event in
                Button {
                    env.router.navigate(to: .event(beaconID: event.beaconID))
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(ClickTypography.body).foregroundStyle(ClickColors.textPrimary)
                            if let start = event.startsAt {
                                Text(start.formatted(date: .abbreviated, time: .shortened))
                                    .font(ClickTypography.supporting)
                                    .foregroundStyle(ClickColors.textSecondary)
                            }
                        }
                        Spacer()
                        if event.isLive { StatusPill("Live", style: .live) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func clicksSection(_ detail: PlaceDetail) -> some View {
        let been = detail.clicksBeenHere.flatMap { $0.count > 0 ? $0 : nil }
        let met = detail.youMetHere.flatMap { $0.total > 0 ? $0 : nil }
        if been != nil || met != nil {
            Section("Your Clicks") {
                if let been {
                    Text("\(PlaceCopy.names(been.names, total: been.count)) \(been.count == 1 ? "has" : "have") been here")
                        .font(ClickTypography.body)
                }
                if let met {
                    Button {
                        showingMetHere = true
                    } label: {
                        Text("You met \(PlaceCopy.names(met.people.map(\.name), total: met.total)) here")
                            .font(ClickTypography.body)
                            .foregroundStyle(ClickColors.textPrimary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func historySection(_ detail: PlaceDetail) -> some View {
        if let history = detail.ownHistory, history.checkInCount > 0 || history.encounterCount > 0 {
            Section("Your history") {
                if history.checkInCount > 0 {
                    let times = history.checkInCount == 1 ? "once" : "\(history.checkInCount) times"
                    let last = history.lastCheckInAt.map { " · Last on \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""
                    Text("You've checked in \(times)\(last)").font(ClickTypography.body)
                }
                if history.encounterCount > 0 {
                    Text(history.encounterCount == 1 ? "1 Click made here" : "\(history.encounterCount) Clicks made here")
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                }
            }
        }
    }

    private func communitySection(_ hub: PlaceHubRef) -> some View {
        Section("Community") {
            Button {
                env.router.navigate(to: .hub(hubID: hub.id))
            } label: {
                HStack {
                    Label("Place Hub", systemImage: "bubble.left.and.bubble.right.fill")
                        .foregroundStyle(ClickColors.textPrimary)
                    Spacer()
                    if !hub.joined {
                        Text("Check in to join").font(ClickTypography.supporting).foregroundStyle(ClickColors.textSecondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func aboutSection(_ detail: PlaceDetail) -> some View {
        Section("About") {
            if let description = detail.description { Text(description).font(ClickTypography.body) }
            if let website = detail.websiteURL {
                Link(destination: website) { Label("Website", systemImage: "globe") }
            }
            if let apple = detail.appleMapsURL {
                Button {
                    openURL(apple)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        if let address = detail.summary.addressLine {
                            Text(address).font(ClickTypography.supporting).foregroundStyle(ClickColors.textSecondary)
                        }
                    }
                }
                .contextMenu {
                    Button("Open in Apple Maps") { openURL(apple) }
                    if let google = detail.googleMapsURL {
                        Button("Open in Google Maps") { openURL(google) }
                    }
                }
            }
        }
    }

    static func categoryLine(_ question: String, counts: [Int]) -> String {
        let labels: [String] = switch question {
        case "seats": ["Plenty", "Some", "None"]
        case "equipment": ["None", "Some", "Long"]
        default: ["None", "Short", "Long"]
        }
        let title: String = switch question {
        case "seats": "Seats"
        case "line": "Line"
        case "wait": "Wait"
        default: "Equipment wait"
        }
        let parts = zip(labels, counts).map { "\($0) \($1)" }
        return "\(title): " + parts.joined(separator: " · ")
    }
}

/// Raw report counts, Chill … Packed.
private struct EnergyBars: View {
    let distribution: [Int]

    var body: some View {
        let total = max(1, distribution.reduce(0, +))
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(EnergyLabel.allCases.enumerated()), id: \.offset) { index, label in
                let count = index < distribution.count ? distribution[index] : 0
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(label.color.opacity(count > 0 ? 1 : 0.2))
                        .frame(height: max(4, 36 * CGFloat(count) / CGFloat(total)))
                    Text("\(label.title) \(count)")
                        .font(.caption2)
                        .foregroundStyle(ClickColors.textSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 56, alignment: .bottom)
        .accessibilityElement(children: .combine)
    }
}

/// §6.8: four energy chips (one tap submits), then optional follow-ups while editable.
private struct PulseCard: View {
    @Bindable var model: PlaceDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.pulseSubmitted {
                Text("Thanks — Pulse updated").font(ClickTypography.bodyEmphasized)
                ForEach(model.remainingFollowUps()) { question in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(question.prompt).font(ClickTypography.supporting)
                        HStack {
                            ForEach(question.options, id: \.self) { option in
                                Button(option.label) { Task { await model.answerFollowUp(question, value: option.value) } }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            } else {
                Text(model.detail?.pulseEligibility?.questions.first { $0.key == "energy" }?.prompt ?? "How's the energy?")
                    .font(ClickTypography.bodyEmphasized)
                HStack(spacing: 8) {
                    ForEach(EnergyLabel.allCases, id: \.self) { label in
                        Button {
                            Task { await model.submitEnergy(label.value) }
                        } label: {
                            Text(label.title)
                                .font(ClickTypography.supportingEmphasized)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(label.color)
                        .disabled(!model.energyChipsEnabled)
                    }
                }
                if let until = model.detail?.pulseEligibility?.cooldownUntil, model.detail?.pulseEligibility?.reason == .cooldown {
                    Text("You can update your Pulse at \(until.formatted(date: .omitted, time: .shortened))")
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                }
                if case .failed(let error) = model.pulsePhase {
                    Text(error.message).font(ClickTypography.supporting).foregroundStyle(ClickColors.destructive)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// "Come back at this time?" after Leave: shown for 30 s or until answered or dismissed.
private struct WouldReturnCard: View {
    let question: PulseQuestion
    let onAnswer: (Int?) -> Void

    var body: some View {
        HStack {
            Text(question.prompt).font(ClickTypography.supporting)
            Spacer()
            ForEach(question.options, id: \.self) { option in
                Button(option.label) { onAnswer(option.value) }.buttonStyle(.bordered)
            }
            Button {
                onAnswer(nil)
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Dismiss")
        }
        .task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { onAnswer(nil) }
        }
    }
}

/// People you met here, with when (your own history).
private struct MetHereSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let people: [PlacePerson]

    var body: some View {
        NavigationStack {
            List(people) { person in
                Button {
                    dismiss()
                    env.router.navigate(to: .userProfile(userID: person.userID, connectionID: nil))
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(imageURL: person.avatarURL?.absoluteString, seed: person.userID, initials: String(person.name.prefix(1)), size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name).font(ClickTypography.body).foregroundStyle(ClickColors.textPrimary)
                            if let met = person.lastMetAt {
                                Text("Last met \(met.formatted(date: .abbreviated, time: .omitted))")
                                    .font(ClickTypography.supporting)
                                    .foregroundStyle(ClickColors.textSecondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("You met here")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
