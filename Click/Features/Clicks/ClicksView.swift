import SwiftUI

/// Phase 3 native Clicks directory backed by authenticated connection data.
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
            VStack(spacing: ClickSpacing.sm) {
                if refreshError != nil {
                    HStack(spacing: ClickSpacing.xs) {
                        Image(systemName: "wifi.exclamationmark")
                        Text("Showing your last saved Clicks")
                        Spacer()
                        Button("Retry") { Task { await refresh() } }
                    }
                    .font(ClickTypography.labelMedium)
                    .foregroundStyle(ClickColors.textSecondary)
                }

                HStack(spacing: ClickSpacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(ClickColors.outline)
                    TextField("Filter by name, handle, place, or interest…", text: $searchQuery)
                        .font(ClickTypography.bodyMedium)
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(ClickColors.outline)
                        }
                    }
                }
                .padding(.horizontal, ClickSpacing.md)
                .padding(.vertical, 10)
                .background(ClickColors.surfaceContainerLow)
                .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusInput))

                HStack(spacing: ClickSpacing.xs) {
                    ForEach(ConnectionSegment.allCases) { segment in
                        let selected = segment == selectedSegment
                        Button {
                            ClickHaptics.selection()
                            selectedSegment = segment
                        } label: {
                            Text(segment.rawValue)
                                .font(ClickTypography.labelMedium)
                                .fontWeight(selected ? .bold : .medium)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(selected ? ClickColors.primary : ClickColors.surfaceContainerLow)
                                .foregroundStyle(selected ? ClickColors.onPrimary : ClickColors.textPrimary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, ClickSpacing.lg)
            .padding(.top, ClickSpacing.sm)
            .padding(.bottom, ClickSpacing.sm)

            if snapshot == nil {
                Spacer()
                ProgressView()
                Spacer()
            } else if filteredConnections.isEmpty {
                EmptyConnectionsStateView(segment: selectedSegment, query: searchQuery)
            } else {
                ScrollView {
                    LazyVStack(spacing: ClickSpacing.sm) {
                        ForEach(filteredConnections) { connection in
                            ConnectionCard(
                                connection: connection,
                                onTap: {
                                    let chatID = connection.connectionID.isEmpty ? connection.userID : connection.connectionID
                                    guard !chatID.isEmpty else { return }
                                    env.router.connectionsPath.append(.chat(chatID: chatID))
                                },
                                onTapProfile: {
                                    guard !connection.userID.isEmpty else { return }
                                    env.router.connectionsPath.append(
                                        .userProfile(
                                            userID: connection.userID,
                                            connectionID: connection.connectionID.isEmpty ? nil : connection.connectionID
                                        )
                                    )
                                }
                            )
                        }
                    }
                    .padding(.horizontal, ClickSpacing.lg)
                    .padding(.top, ClickSpacing.xs)
                    .padding(.bottom, ClickSpacing.xxl)
                }
                .refreshable { await refresh() }
            }
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle("Clicks")
        .navigationBarTitleDisplayMode(.inline)
        .task { await bootstrap() }
    }

    @MainActor
    private func bootstrap() async {
        guard snapshot == nil, let userID = env.session.currentSession?.userId else { return }
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

private struct ConnectionCard: View {
    let connection: ConnectionItem
    let onTap: () -> Void
    var onTapProfile: (() -> Void)? = nil

    private var avatarFallback: some View {
        Circle()
            .fill(ClickColors.primaryFixed.opacity(0.4))
            .overlay(
                Text(connection.initials)
                    .font(ClickTypography.titleSmall)
                    .fontWeight(.bold)
                    .foregroundStyle(ClickColors.primary)
            )
    }

    var body: some View {
        Button {
            ClickHaptics.selection()
            onTap()
        } label: {
            VStack(alignment: .leading, spacing: ClickSpacing.sm) {
                HStack(spacing: ClickSpacing.md) {
                    ZStack(alignment: .bottomTrailing) {
                        Group {
                            if let raw = connection.avatarUrl, let url = URL(string: raw) {
                                AsyncImage(url: url) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    avatarFallback
                                }
                            } else {
                                avatarFallback
                            }
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(Circle())
                        .onTapGesture {
                            ClickHaptics.selection()
                            onTapProfile?()
                        }

                        if connection.presenceKnown {
                            Circle()
                                .fill(connection.isOnline ? Color(hex: "#10B981") : ClickColors.outline.opacity(0.4))
                                .frame(width: 12, height: 12)
                                .overlay(Circle().stroke(ClickColors.background, lineWidth: 2))
                        }
                    }

                    VStack(alignment: .leading, spacing: ClickSpacing.xxxSmall) {
                        Text(connection.displayName)
                            .font(ClickTypography.titleSmall)
                            .fontWeight(.semibold)
                            .foregroundStyle(ClickColors.textPrimary)

                        if !connection.handle.isEmpty {
                            Text(connection.handle)
                                .font(ClickTypography.bodySmall)
                                .foregroundStyle(ClickColors.textSecondary)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: ClickSpacing.xxxSmall) {
                        if !connection.lastActiveRelative.isEmpty {
                            Text(connection.lastActiveRelative)
                                .font(ClickTypography.labelSmall)
                                .foregroundStyle(ClickColors.textSecondary)
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ClickColors.outline)
                    }
                }

                HStack(spacing: ClickSpacing.xs) {
                    if !connection.encounterLocation.isEmpty {
                        HStack(spacing: ClickSpacing.xxs) {
                            Image(systemName: "mappin")
                                .font(.system(size: 10))
                            Text(connection.encounterLocation)
                                .font(ClickTypography.labelSmall)
                        }
                        .foregroundStyle(ClickColors.textSecondary)
                    }

                    ForEach(connection.mutualTags.prefix(2), id: \.self) { tag in
                        Text(tag)
                            .font(ClickTypography.labelSmall)
                            .foregroundStyle(ClickColors.primary)
                    }
                }
            }
            .padding(ClickSpacing.md)
            .background(ClickColors.surfaceContainerLow)
            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard))
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyConnectionsStateView: View {
    let segment: ConnectionSegment
    let query: String

    var body: some View {
        VStack(spacing: ClickSpacing.md) {
            Spacer()
            Image(systemName: "person.2.slash")
                .font(.system(size: 48))
                .foregroundStyle(ClickColors.outline)
            Text(query.isEmpty ? "No \(segment.rawValue) Clicks" : "No results for “\(query)”")
                .font(ClickTypography.titleMedium)
                .fontWeight(.bold)
                .foregroundStyle(ClickColors.textPrimary)
            Text(query.isEmpty ? "New connections will appear here." : "Try a different name, place, or interest.")
                .font(ClickTypography.bodySmall)
                .foregroundStyle(ClickColors.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, ClickSpacing.lg)
    }
}
