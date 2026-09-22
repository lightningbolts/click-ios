import SwiftUI

@main
struct ClickApp: App {
    @State private var environment: AppEnvironment

    init() {
        // Explicit State initialization avoids an Xcode 16.4 Swift 6 SILGen crash seen when
        // lowering the @MainActor AppEnvironment default stored-property initializer.
        _environment = State(initialValue: AppEnvironment())
        ClickFonts.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootGateView()
                .environment(environment)
                .task {
                    if CommandLine.arguments.contains("-preview-profile-basics") {
                        environment.session.requireProfileBasics(userId: "usr_preview_99")
                    } else if CommandLine.arguments.contains("-preview-shell")
                        || CommandLine.arguments.contains("-preview-home")
                        || CommandLine.arguments.contains("-preview-clicks")
                        || CommandLine.arguments.contains("-preview-profile") {
                        environment.session.signIn(
                            snapshot: SessionSnapshot(
                                userId: "usr_preview_active",
                                jwt: "mock_jwt",
                                refreshToken: "mock_refresh"
                            )
                        )
                    } else if CommandLine.arguments.contains(where: { $0.hasPrefix("-preview-onboarding") }) {
                        environment.session.signIn(
                            snapshot: SessionSnapshot(
                                userId: "usr_preview_onboarding",
                                jwt: "mock_jwt",
                                refreshToken: "mock_refresh"
                            )
                        )
                    } else if CommandLine.arguments.contains("-preview-signup") || CommandLine.arguments.contains("-preview-signin") {
                        await environment.session.signOut()
                    } else {
                        await environment.bootstrap()
                    }
                }
                .onOpenURL { url in
                    environment.handleIncomingURL(url)
                }
        }
    }
}
