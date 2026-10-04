import StoreKit
import SwiftUI

@main
struct ClipApp: App {
    @State private var model = ClipModel()

    var body: some Scene {
        WindowGroup {
            ClipRootView(model: model)
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    Task { await model.open(activity.webpageURL) }
                }
                .task {
                    #if DEBUG
                    // `-clip-url https://joinclick.co/c/…` previews an invocation without a QR code.
                    if let index = CommandLine.arguments.firstIndex(of: "-clip-url"),
                       CommandLine.arguments.indices.contains(index + 1) {
                        await model.open(URL(string: CommandLine.arguments[index + 1]))
                    }
                    #endif
                }
        }
    }
}

/// The App Clip: a real preview of what the link is for (the person, the event, the Place) with
/// the next step, and the system "Get Click" banner to finish in the full app.
struct ClipRootView: View {
    let model: ClipModel
    @State private var showsOverlay = false

    private static let purple = Color(red: 0x7C / 255, green: 0x3A / 255, blue: 0xED / 255)

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image("ClickLogoMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .padding(.top, 12)
                content
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 180)
            .frame(maxWidth: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Self.purple)
        .appStoreOverlay(isPresented: $showsOverlay) {
            SKOverlay.AppClipConfiguration(position: .bottom)
        }
        .task(id: model.destination) {
            // Let the preview land first, then offer the full app.
            try? await Task.sleep(for: .seconds(1.2))
            showsOverlay = true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.destination {
        case .connect:
            connect
        case .event:
            event
        case .place:
            message(
                systemImage: "mappin.circle.fill",
                title: "You're at a Click Place",
                body: "Check in with Click to see which of your Clicks have been here, share a Pulse about the vibe, and catch what's happening tonight."
            )
            nextSteps(["Get Click below", "Sign in, then scan this code again to check in"])
        case .home:
            message(
                systemImage: "person.2.wave.2.fill",
                title: "Meet people for real",
                body: "Click turns meeting someone in person into a lasting connection. Tap phones or scan a Click code, and you're connected with a timeline of where you met."
            )
            nextSteps(["Get Click below", "Scan a friend's Click code or tap phones to connect"])
        }
    }

    // MARK: - Connect

    @ViewBuilder
    private var connect: some View {
        switch model.profile {
        case .loading:
            ProgressView().padding(.top, 60)
        case .failed:
            message(systemImage: "qrcode", title: "This code has expired",
                    body: "Ask them to show their Click code again, or get Click to connect.")
        case .loaded(let profile):
            VStack(spacing: 14) {
                avatar(profile)
                Text("Connect with \(profile.firstName)")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text("\(profile.displayName) wants to connect with you on Click. Your connection keeps where and when you met, so you'll never lose track of each other.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            nextSteps([
                "Get Click below and sign in",
                "Scan \(profile.firstName)'s code again, or tap phones",
                "Say hi within 48 hours to keep the connection"
            ])
        }
    }

    private func avatar(_ profile: ClipProfile) -> some View {
        let colors = profile.auraColors.compactMap(Color.init(hex:))
        let ring = colors.isEmpty ? [Self.purple, .pink] : colors
        return AsyncImage(url: profile.avatarURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(String(profile.displayName.prefix(1)))
                .font(.system(size: 44, weight: .bold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.08))
        }
        .frame(width: 120, height: 120)
        .clipShape(Circle())
        .padding(5)
        .background(Circle().fill(AngularGradient(colors: ring + [ring[0]], center: .center)))
        .accessibilityHidden(true)
    }

    // MARK: - Event

    @ViewBuilder
    private var event: some View {
        switch model.event {
        case .loading:
            ProgressView().padding(.top, 60)
        case .failed:
            message(systemImage: "calendar.badge.exclamationmark", title: "This event isn't available",
                    body: "It may have ended or been removed. Get Click to see what's happening near you.")
        case .loaded(let event):
            VStack(alignment: .leading, spacing: 14) {
                if let imageURL = event.imageURL {
                    AsyncImage(url: imageURL) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.06) }
                        .frame(height: 180)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .accessibilityHidden(true)
                }
                Text(event.displayTitle)
                    .font(.title.bold())
                VStack(alignment: .leading, spacing: 8) {
                    if let startsAt = event.startsAt {
                        Label(startsAt.formatted(.dateTime.weekday(.wide).month().day().hour().minute()), systemImage: "calendar")
                    }
                    if let place = event.locationName {
                        Label(place, systemImage: "mappin.and.ellipse")
                    }
                    if let host = event.hostName {
                        Label("Hosted by \(host)", systemImage: "person.crop.circle")
                    }
                    if let count = event.rsvpCount, count > 0 {
                        Label("\(count) going", systemImage: "person.2")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if let description = event.description, description != event.displayTitle {
                    Text(description).font(.body)
                }
                if let directions = event.directionsURL {
                    Link(destination: directions) {
                        Label("Directions", systemImage: "location.north.line")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            nextSteps(["Get Click below to RSVP", "Check in when you arrive to meet who's there"])
        }
    }

    // MARK: - Pieces

    private func message(systemImage: String, title: String, body: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 52))
                .foregroundStyle(Self.purple)
                .padding(.top, 24)
            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func nextSteps(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Self.purple))
                    Text(step).font(.body)
                }
            }
            Button {
                showsOverlay = true
            } label: {
                Text("Get Click")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .padding(.top, 6)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private extension Color {
    /// "#RRGGBB" aura colors from the profile.
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
