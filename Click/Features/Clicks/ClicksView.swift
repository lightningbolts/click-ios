import SwiftUI

/// Phase 3 native Clicks directory screen.
public struct ClicksView: View {
    @State private var snapshot: ClicksSnapshot
    @State private var selectedSegment: ConnectionSegment = .all
    @State private var searchQuery: String = ""
    @State private var selectedConnectionId: String?

    public init(initialSnapshot: ClicksSnapshot = .preview) {
        self._snapshot = State(initialValue: initialSnapshot)
    }

    private var filteredConnections: [ConnectionItem] {
        snapshot.filtered(by: selectedSegment, query: searchQuery)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Search & Segmented Filter
            VStack(spacing: ClickSpacing.sm) {
                // Search Bar
                HStack(spacing: ClickSpacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(ClickColors.outline)
                    TextField("Filter by name, handle, or interest…", text: $searchQuery)
                        .font(ClickTypography.bodyMedium)
                    if !searchQuery.isEmpty {
                        Button(action: { searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(ClickColors.outline)
                        }
                    }
                }
                .padding(.horizontal, ClickSpacing.md)
                .padding(.vertical, 10)
                .background(ClickColors.surfaceContainerLow)
                .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusInput))
                .overlay(
                    RoundedRectangle(cornerRadius: ClickSpacing.radiusInput)
                        .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                )

                // Segment Picker Bar
                HStack(spacing: ClickSpacing.xs) {
                    ForEach(ConnectionSegment.allCases) { segment in
                        let isSelected = segment == selectedSegment
                        Button(action: {
                            ClickHaptics.selection()
                            selectedSegment = segment
                        }) {
                            Text(segment.rawValue)
                                .font(ClickTypography.labelMedium)
                                .fontWeight(isSelected ? .bold : .medium)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(isSelected ? ClickColors.primary : ClickColors.surfaceContainerLow)
                                .foregroundStyle(isSelected ? ClickColors.onPrimary : ClickColors.textPrimary)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(isSelected ? ClickColors.primary : ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, ClickSpacing.lg)
            .padding(.top, ClickSpacing.sm)
            .padding(.bottom, ClickSpacing.sm)
            .background(ClickColors.background)

            // Connection List or Empty State
            if filteredConnections.isEmpty {
                EmptyConnectionsStateView(segment: selectedSegment, query: searchQuery)
            } else {
                ScrollView {
                    LazyVStack(spacing: ClickSpacing.sm) {
                        ForEach(filteredConnections) { connection in
                            ConnectionCard(connection: connection) {
                                selectedConnectionId = connection.id
                            }
                        }
                    }
                    .padding(.horizontal, ClickSpacing.lg)
                    .padding(.top, ClickSpacing.xs)
                    .padding(.bottom, ClickSpacing.xxl)
                }
            }
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle("Clicks")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Rich connection card shown in the Clicks list.
private struct ConnectionCard: View {
    let connection: ConnectionItem
    let onTap: () -> Void

    var body: some View {
        Button(action: {
            ClickHaptics.selection()
            onTap()
        }) {
            VStack(alignment: .leading, spacing: ClickSpacing.sm) {
                HStack(spacing: ClickSpacing.md) {
                    // Avatar + Presence Dot
                    ZStack(alignment: .bottomTrailing) {
                        Circle()
                            .fill(ClickColors.primaryFixed.opacity(0.4))
                            .frame(width: 48, height: 48)
                            .overlay(
                                Text(connection.initials)
                                    .font(ClickTypography.titleSmall)
                                    .fontWeight(.bold)
                                    .foregroundStyle(ClickColors.primary)
                            )

                        Circle()
                            .fill(connection.isOnline ? Color(hex: "#10B981") : ClickColors.outline.opacity(0.4))
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle()
                                    .stroke(ClickColors.background, lineWidth: 2)
                            )
                    }

                    VStack(alignment: .leading, spacing: ClickSpacing.xxxSmall) {
                        Text(connection.displayName)
                            .font(ClickTypography.titleSmall)
                            .fontWeight(.semibold)
                            .foregroundStyle(ClickColors.textPrimary)

                        Text(connection.handle)
                            .font(ClickTypography.bodySmall)
                            .foregroundStyle(ClickColors.textSecondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: ClickSpacing.xxxSmall) {
                        Text(connection.lastActiveRelative)
                            .font(ClickTypography.labelSmall)
                            .foregroundStyle(connection.isOnline ? ClickColors.primary : ClickColors.textSecondary)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ClickColors.outline)
                    }
                }

                // Encounter location & mutual tag badges
                HStack(spacing: ClickSpacing.xs) {
                    if !connection.encounterLocation.isEmpty {
                        HStack(spacing: ClickSpacing.xxs) {
                            Image(systemName: "mappin")
                                .font(.system(size: 10))
                            Text(connection.encounterLocation)
                                .font(ClickTypography.labelSmall)
                        }
                        .foregroundStyle(ClickColors.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(ClickColors.surfaceContainerHigh)
                        .clipShape(Capsule())
                    }

                    ForEach(connection.mutualTags.prefix(2), id: \.self) { tag in
                        Text(tag)
                            .font(ClickTypography.labelSmall)
                            .foregroundStyle(ClickColors.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(ClickColors.primaryFixed.opacity(0.35))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(ClickSpacing.md)
            .background(ClickColors.surfaceContainerLow)
            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: ClickSpacing.radiusCard)
                    .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Empty state presentation when no connections match filters.
private struct EmptyConnectionsStateView: View {
    let segment: ConnectionSegment
    let query: String

    var body: some View {
        VStack(spacing: ClickSpacing.md) {
            Spacer()

            Image(systemName: "person.2.slash")
                .font(.system(size: 48))
                .foregroundStyle(ClickColors.outline)

            VStack(spacing: ClickSpacing.xs) {
                Text(query.isEmpty ? "No \(segment.rawValue) connections" : "No results for \"\(query)\"")
                    .font(ClickTypography.titleMedium)
                    .fontWeight(.bold)
                    .foregroundStyle(ClickColors.textPrimary)

                Text(query.isEmpty ? "When you make new connections or join circles, they will appear here." : "Try searching for a different name, handle, or interest.")
                    .font(ClickTypography.bodySmall)
                    .foregroundStyle(ClickColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ClickSpacing.xl)
            }

            Spacer()
        }
        .padding(.horizontal, ClickSpacing.lg)
    }
}
