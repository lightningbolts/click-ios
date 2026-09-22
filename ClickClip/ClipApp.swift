import SwiftUI

@main
struct ClipApp: App {
    @State private var connectionID: String?

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Image(systemName: "circle.circle.fill")
                    .resizable()
                    .frame(width: 56, height: 56)
                    .foregroundStyle(.blue)

                Text("Click Connect")
                    .font(.title2.bold())

                if let id = connectionID {
                    Text("Ready to connect with profile \(id)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap or scan to connect")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let incomingURL = activity.webpageURL else { return }
                let components = incomingURL.pathComponents.filter { $0 != "/" }
                if let first = components.first, first == "c", components.count > 1 {
                    connectionID = components[1]
                }
            }
        }
    }
}
