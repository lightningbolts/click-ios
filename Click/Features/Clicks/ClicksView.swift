import SwiftUI

/// Native Clicks inbox backed by authenticated connection data.
///
/// The root deliberately uses native large-title/search behavior and a flat inbox hierarchy rather
/// than stacking card-on-card surfaces.
public struct ClicksView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var snapshot: ClicksSnapshot?
    @State private var selectedSegment: ConnectionSegment = .all
    @State private var searchQuery = ""
    @State private var refreshError: String?

    public init(initialSnapshot: ClicksSnapshot? = nil) {
        self._snapshot = State(initialValue: initialSnapshot)
    }

    private var filteredConnections: [ConnectionItem] {
        snapshot?.filtered(by: selectedSegment, query: searchQuery) ?? []
    }

    public var body: some View {
        VStack(spacing: 0) {
            if refreshError != nil {
                cachedBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }

            segmentControl
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()
                .overlay(ClickColors.quietBorder.opacity(0.7))

            content
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle("Clicks")
        .navigationBarTitleDisplayMode(.large)
        .searchable(
            text: $searchQuery,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search names, places, interests"
        )
        .tint(ClickColors.primary)
        .task { await bootstrap() }
    }

    @ViewBuilder
    private var content: some View {
        if snapshot == nil {
            VStack(spacing: 10) {
                Spacer()
                ProgressView()
                    .tint(ClickColors.primary)
                Text("Loading Clicks…")
                    .font(ClickTypography.bodySmall)
                    .foregroundStyle(ClickColors.textSecondary)
                Spacer()
            }
        } else if filteredConnections.isEmpty {
            ContentUnavailableView {
                Label(
                    searchQuery.isEmpty
                        ? "No \(selectedSegment.rawValue) Clicks"
                        : "No matching Clicks",
                    systemImage: searchQuery.isEmpty ? "person.2" : "magnifyingglass"
                )
            } description: {
                Text(
                    searchQuery.isEmpty
                        ? "Connections in this view will appear here."
                        : "Try another name, place, handle, or interest."
                )
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredConnections) { connection in
                        ConnectionRow(
                            connection: connection,
                            onOpenChat: {
                                guard !connection.userID.isEmpty else { return }
                                ClickHaptics.selection()
                                env.router.connectionsPath.append(
                                    .chat(
                                        DirectChatRoute(
                                            chatID: nil,
                                            connectionID: connection.connectionID,
                                            peerUserID: connection.userID,
                                            peerDisplayName: connection.displayName,
                                            peerHandle: connection.handle,
                                            peerAvatarURL: connection.avatarUrl,
                                            isOnline: connection.isOnline,
                                            lastActiveText: connection.lastActiveRelative
                                        )
                                    )
                                )
                            },
                            onOpenProfile: {
                                guard !connection.userID.isEmpty else { return }
                                ClickHaptics.selection()
                                env.router.connectionsPath.append(
                                    .userProfile(
                                        userID: connection.userID,
                                        connectionID: connection.connectionID.isEmpty
                                            ? nil
                                            : connection.connectionID
                                    )
                                )
                            }
                        )

                        if connection.id != filteredConnections.last?.id {
                            Divider()
                                .overlay(ClickColors.quietBorder.opacity(0.62))
                                .padding(.leading, 76)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .refreshable { await refresh() }
        }
    }

    private var segmentControl: some View {
        Picker("Connection filter", selection: $selectedSegment) {
            ForEach(ConnectionSegment.allCases) { segment in
                Text(segment.rawValue)
                    .tag(segment)
            }
        }
        .pickerStyle(.segmented)
        .tint(ClickColors.primary)
        .onChange(of: selectedSegment) { _, _ in
            ClickHaptics.selection()
        }
    }

    private var cachedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 12, weight: .semibold))

            Text("Showing saved Clicks")
                .font(ClickTypography.captionSmall)

            Spacer()

            Button("Retry") {
                Task { await refresh() }
            }
            .font(ClickTypography.captionSmall)
        }
        .foregroundStyle(ClickColors.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ClickColors.surfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @MainActor
    private func bootstrap() async {
        guard snapshot == nil,
              let userID = env.session.currentSession?.userId else { return }

        if let cached = await env.phase3.cachedClicks(for: userID) {
            snapshot = cached
        }
        await refresh()
    }

    @MainActor
    private func refresh() async {
        guard let userID = env.session.currentSession?.userId else { return }

        do {
            snapshot = try await env.phase3.refreshClicks(for: userID)
            refreshError = nil
        } catch {
            refreshError = error.localizedDescription
        }
    }
}

private struct ConnectionRow: View {
    let connection: ConnectionItem
    let onOpenChat: () -> Void
    let onOpenProfile: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpenProfile) {
                avatar
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(connection.displayName) profile")

            Button(action: onOpenChat) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(connection.displayName)
                                .font(ClickTypography.titleMedium)
                                .foregroundStyle(ClickColors.textPrimary)
                                .lineLimit(1)

                            if !connection.handle.isEmpty {
                                Text(connection.handle)
                                    .font(ClickTypography.bodySmall)
                                    .foregroundStyle(ClickColors.textSecondary)
                                    .lineLimit(1)
                            }
                        }

                        metadataLine
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 7) {
                        if !connection.lastActiveRelative.isEmpty {
                            Text(connection.lastActiveRelative)
                                .font(ClickTypography.microcopy)
                                .foregroundStyle(
                                    connection.isOnline
                                        ? ClickColors.primary
                                        : ClickColors.textSecondary
                                )
                                .lineLimit(1)
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ClickColors.tertiaryLabel)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(ClickColors.background)
    }

    @ViewBuilder
    private var metadataLine: some View {
        HStack(spacing: 5) {
            if !connection.encounterLocation.isEmpty {
                Image(systemName: "mappin")
                    .font(.system(size: 10, weight: .semibold))

                Text(connection.encounterLocation)
                    .lineLimit(1)
            }

            if !connection.encounterLocation.isEmpty,
               !connection.mutualTags.isEmpty {
                Text("·")
            }

            if let firstTag = connection.mutualTags.first {
                Text(firstTag)
                    .lineLimit(1)
            }

            if connection.mutualTags.count > 1 {
                Text("+\(connection.mutualTags.count - 1)")
                    .foregroundStyle(ClickColors.primary)
            }
        }
        .font(ClickTypography.bodySmall)
        .foregroundStyle(ClickColors.textSecondary)
    }

    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let raw = connection.avatarUrl,
                   let url = URL(string: raw) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        fallbackAvatar
                    }
                } else {
                    fallbackAvatar
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(Circle())

            if connection.presenceKnown {
                Circle()
                    .fill(
                        connection.isOnline
                            ? ClickColors.statusOnline
                            : ClickColors.statusOffline
                    )
                    .frame(width: 12, height: 12)
                    .overlay {
                        Circle()
                            .stroke(ClickColors.background, lineWidth: 2)
                    }
            }
        }
    }

    private var fallbackAvatar: some View {
        Circle()
            .fill(ClickColors.primaryFixed.opacity(0.48))
            .overlay {
                Text(connection.initials)
                    .font(ClickTypography.titleSmall)
                    .foregroundStyle(ClickColors.primary)
            }
    }
}
