import SwiftUI

/// Top-level gate view that manages authentication and onboarding transitions without visual flash.
public struct RootGateView: View {
    @Environment(AppEnvironment.self) private var env

    public init() {}

    public var body: some View {
        Group {
            switch env.session.state {
            case .restoring:
                LaunchLoadingView()
            case .unauthenticated, .terminalError:
                AuthPlaceholderView()
            case .authenticated, .refreshing, .offlineAuthenticated:
                MainTabShellView()
            }
        }
        .animation(ClickMotion.subtleFade, value: env.session.state)
    }
}

/// Subtle initial launch loading view avoiding visual jump.
private struct LaunchLoadingView: View {
    var body: some View {
        ZStack {
            ClickColors.background.ignoresSafeArea()
            VStack(spacing: ClickSpacing.medium) {
                Image(systemName: "circle.circle.fill")
                    .resizable()
                    .frame(width: 48, height: 48)
                    .foregroundStyle(ClickColors.brandElectric)
                ProgressView()
                    .tint(ClickColors.brandElectric)
            }
        }
    }
}

/// Phase 0 auth placeholder. Real email/OAuth auth implemented in Phase 1.
private struct AuthPlaceholderView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationStack {
            VStack(spacing: ClickSpacing.large) {
                Spacer()
                Image(systemName: "circle.circle.fill")
                    .resizable()
                    .frame(width: 64, height: 64)
                    .foregroundStyle(ClickColors.brandElectric)

                Text("Click")
                    .font(ClickTypography.largeTitle)
                    .foregroundStyle(ClickColors.label)

                Text("In-person first connection & private messaging.")
                    .font(ClickTypography.body)
                    .foregroundStyle(ClickColors.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ClickSpacing.large)

                Spacer()

                Button {
                    // Demo sign-in for testing the shell
                    env.session.signIn(
                        snapshot: SessionSnapshot(
                            userId: "mock_user_\(UUID().uuidString.prefix(8))",
                            jwt: "mock_jwt_token",
                            refreshToken: "mock_refresh_token"
                        )
                    )
                } label: {
                    Text("Continue with Demo Session")
                        .font(ClickTypography.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, ClickSpacing.medium)
                        .background(ClickColors.brandElectric)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusMedium))
                }
                .padding(.horizontal, ClickSpacing.xLarge)
                .padding(.bottom, ClickSpacing.xxLarge)
            }
            .background(ClickColors.background.ignoresSafeArea())
        }
    }
}

/// The 5-tab main shell view (Home, Add Click, Clicks, Map, Me).
private struct MainTabShellView: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable private var router: AppRouter

    init() {
        // Safe placeholder initialization; router is extracted from env on body
        self._router = Bindable(AppRouter())
    }

    var body: some View {
        @Bindable var r = env.router
        TabView(selection: $r.selectedTab) {
            Tab("Home", systemImage: "house.fill", value: MainTab.home) {
                NavigationStack(path: $r.homePath) {
                    FeedPlaceholderView(title: "Home")
                }
            }

            Tab("Add Click", systemImage: "plus.circle.fill", value: MainTab.addClick) {
                NavigationStack(path: $r.addClickPath) {
                    FeedPlaceholderView(title: "Add Click")
                }
            }

            Tab("Clicks", systemImage: "bubble.left.and.bubble.right.fill", value: MainTab.connections) {
                NavigationStack(path: $r.connectionsPath) {
                    FeedPlaceholderView(title: "Clicks")
                }
            }

            Tab("Map", systemImage: "map.fill", value: MainTab.map) {
                NavigationStack(path: $r.mapPath) {
                    FeedPlaceholderView(title: "Map")
                }
            }

            Tab("Me", systemImage: "person.circle.fill", value: MainTab.settings) {
                NavigationStack(path: $r.settingsPath) {
                    SettingsPlaceholderView()
                }
            }
        }
    }
}

private struct FeedPlaceholderView: View {
    let title: String

    var body: some View {
        VStack(spacing: ClickSpacing.medium) {
            Text(title)
                .font(ClickTypography.title)
            Text("Native implementation vertical slice")
                .font(ClickTypography.subheadline)
                .foregroundStyle(ClickColors.secondaryLabel)
        }
        .navigationTitle(title)
        .background(ClickColors.background)
    }
}

private struct SettingsPlaceholderView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section("Account") {
                if let session = env.session.currentSession {
                    LabeledContent("User ID", value: session.userId)
                }
                Button("Sign Out", role: .destructive) {
                    Task {
                        await env.session.signOut()
                    }
                }
            }

            Section("Preferences") {
                Toggle("Dark Mode", isOn: Bindable(env.settings).darkModeEnabled)
                Toggle("Message Notifications", isOn: Bindable(env.settings).messageNotificationsEnabled)
            }
        }
        .navigationTitle("Me")
    }
}
