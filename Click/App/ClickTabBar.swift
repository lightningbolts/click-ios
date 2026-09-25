import SwiftUI

/// The app's tab bar, attached to each tab's *root* screen so it slides out and back in with
/// navigation pushes and pops (including interactive back), like WhatsApp. The system tab bar
/// is hidden; `TabView` still owns tab state and per-tab navigation stacks.
struct ClickTabBar: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ConversationListModel.self) private var conversations
    @Environment(MeTabAvatarModel.self) private var meTabAvatar
    @State private var keyboardVisible = false

    var body: some View {
        Group {
            if !keyboardVisible {
                HStack(spacing: 0) {
                    item(.home, title: "Home") { Image(systemName: "house.fill") }
                    item(.addClick, title: "Add Click") {
                        Image(systemName: "plus.circle.fill").foregroundStyle(ClickColors.accentForeground)   // always purple
                    }
                    item(.connections, title: "Clicks", badge: conversations.unreadTotal) { Image(systemName: "person.2.fill") }
                    item(.map, title: "Map") { Image(systemName: "location.fill") }
                    item(.settings, title: "Me") {
                        if let avatar = meTabAvatar.image {
                            Image(uiImage: avatar).resizable().scaledToFill().frame(width: 26, height: 26).clipShape(Circle())
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                        }
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 64)
                .glassCircleBackground()
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    }

    private func item<Icon: View>(_ tab: MainTab, title: String, badge: Int = 0, @ViewBuilder icon: () -> Icon) -> some View {
        let selected = env.router.selectedTab == tab
        return Button {
            if tab == .addClick { ClickHaptics.impact(.medium) } else { ClickHaptics.selection() }
            env.router.selectTab(tab)   // re-tapping the current tab pops to its root
        } label: {
            VStack(spacing: 3) {
                icon()
                    .font(.system(size: 21, weight: .semibold))
                    .frame(height: 26)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text(badge > 99 ? "99+" : "\(badge)")
                                .font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                                .background(Color.red, in: Capsule())
                                .offset(x: 12, y: -6)
                        }
                    }
                Text(title).font(.caption2.weight(.medium))
            }
            .foregroundStyle(selected ? ClickColors.accentForeground : ClickColors.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) unread" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
