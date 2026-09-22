import SwiftUI

/// Phase 2 Prior Connections screen performing genuine on-device privacy-preserving contact matching.
public struct PriorConnectionsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var isSearching: Bool = false
    @State private var searched: Bool = false
    @State private var matches: [DiscoveredContactCard] = []
    @State private var requestedUserIds: Set<String> = []
    @State private var knownSinceByUser: [String: PriorKnownSince] = [:]
    @State private var errorMessage: String?

    let onComplete: () -> Void
    let onSkip: () -> Void

    public init(onComplete: @escaping () -> Void, onSkip: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onSkip = onSkip
    }

    public var body: some View {
        VStack(spacing: 0) {
            OnboardingHeaderView(
                title: "Find your friends",
                subtitle: "Find people you already know on Click. Your contacts are hashed locally on your device and never stored in plain text."
            )

            ScrollView {
                VStack(spacing: ClickSpacing.lg) {
                    // Privacy Trust Box
                    VStack(alignment: .leading, spacing: ClickSpacing.sm) {
                        HStack(spacing: ClickSpacing.sm) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(ClickColors.primary)
                            Text("Privacy-Preserving Contact Matching")
                                .font(ClickTypography.titleSmall)
                                .fontWeight(.semibold)
                                .foregroundStyle(ClickColors.textPrimary)
                        }

                        Text("Only cryptographic hashes (SHA-256) of phone numbers are compared against the backend to find mutual connections. Click never reads or saves your address book.")
                            .font(ClickTypography.bodySmall)
                            .foregroundStyle(ClickColors.textSecondary)
                            .lineSpacing(2)
                    }
                    .padding(ClickSpacing.md)
                    .background(ClickColors.surfaceContainerLow)
                    .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusCard))
                    .overlay(
                        RoundedRectangle(cornerRadius: ClickSpacing.radiusCard)
                            .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                    )
                    .padding(.horizontal, ClickSpacing.lg)

                    if let error = errorMessage {
                        Text(error)
                            .font(ClickTypography.captionSmall)
                            .foregroundStyle(ClickColors.error)
                            .padding(.horizontal, ClickSpacing.lg)
                    }

                    // Matches List (when searched)
                    if searched {
                        if matches.isEmpty {
                            VStack(spacing: ClickSpacing.xs) {
                                Image(systemName: "person.2.slash")
                                    .font(.system(size: 36))
                                    .foregroundStyle(ClickColors.outline)
                                    .padding(.top, ClickSpacing.md)

                                Text("No friends found yet")
                                    .font(ClickTypography.titleSmall)
                                    .foregroundStyle(ClickColors.textPrimary)

                                Text("None of your contacts are on Click yet. You can always connect in person via QR or Tap.")
                                    .font(ClickTypography.bodySmall)
                                    .foregroundStyle(ClickColors.textSecondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, ClickSpacing.lg)
                            }
                            .padding(.vertical, ClickSpacing.md)
                        } else {
                            VStack(alignment: .leading, spacing: ClickSpacing.sm) {
                                Text("Suggested Friends (\(matches.count))")
                                    .font(ClickTypography.labelBold)
                                    .foregroundStyle(ClickColors.textSecondary)
                                    .padding(.horizontal, ClickSpacing.lg)

                                ForEach(matches) { match in
                                    HStack(spacing: ClickSpacing.md) {
                                        Circle()
                                            .fill(ClickColors.surfaceContainerLow)
                                            .frame(width: 44, height: 44)
                                            .overlay(
                                                Text(match.name.prefix(1))
                                                    .font(ClickTypography.titleSmall)
                                                    .foregroundStyle(ClickColors.primary)
                                            )

                                        VStack(alignment: .leading, spacing: ClickSpacing.xxxSmall) {
                                            Text(match.name)
                                                .font(ClickTypography.titleSmall)
                                                .foregroundStyle(ClickColors.textPrimary)

                                            if !match.tags.isEmpty {
                                                Text(match.tags.prefix(2).joined(separator: ", "))
                                                    .font(ClickTypography.captionSmall)
                                                    .foregroundStyle(ClickColors.textSecondary)
                                            }

                                            Menu {
                                                ForEach(PriorKnownSince.allCases) { option in
                                                    Button(option.label) {
                                                        knownSinceByUser[match.id] = option
                                                    }
                                                }
                                            } label: {
                                                HStack(spacing: ClickSpacing.xxxSmall) {
                                                    Text("Known since: \((knownSinceByUser[match.id] ?? .unspecified).label)")
                                                        .font(ClickTypography.captionSmall)
                                                    Image(systemName: "chevron.down")
                                                        .font(.caption2)
                                                }
                                                .foregroundStyle(ClickColors.textSecondary)
                                            }
                                            .disabled(requestedUserIds.contains(match.id))
                                        }

                                        Spacer()

                                        let isRequested = requestedUserIds.contains(match.id)
                                        Button {
                                            sendPriorRequest(to: match.id)
                                        } label: {
                                            Text(isRequested ? "Requested" : "Connect")
                                                .font(ClickTypography.labelMedium)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 7)
                                                .background(isRequested ? ClickColors.surfaceContainerLow : ClickColors.primary)
                                                .foregroundStyle(isRequested ? ClickColors.textSecondary : ClickColors.onPrimary)
                                                .clipShape(Capsule())
                                        }
                                        .disabled(isRequested)
                                    }
                                    .padding(.horizontal, ClickSpacing.lg)
                                    .padding(.vertical, ClickSpacing.xs)
                                }
                            }
                        }
                    }

                    Spacer(minLength: ClickSpacing.xl)

                    // Actions
                    VStack(spacing: ClickSpacing.sm) {
                        if !searched {
                            Button(action: discoverContacts) {
                                HStack(spacing: ClickSpacing.sm) {
                                    if isSearching {
                                        ProgressView()
                                            .tint(ClickColors.onPrimary)
                                        Text("Discovering friends…")
                                            .font(ClickTypography.titleMedium)
                                            .fontWeight(.bold)
                                    } else {
                                        Image(systemName: "person.crop.circle.badge.plus")
                                        Text("Find Friends from Contacts")
                                            .font(ClickTypography.titleMedium)
                                            .fontWeight(.bold)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(ClickColors.primary)
                                .foregroundStyle(ClickColors.onPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusButton))
                            }
                            .disabled(isSearching)
                        } else {
                            Button(action: onComplete) {
                                Text("Continue")
                                    .font(ClickTypography.titleMedium)
                                    .fontWeight(.bold)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                                    .background(ClickColors.primary)
                                    .foregroundStyle(ClickColors.onPrimary)
                                    .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusButton))
                            }
                        }

                        Button(action: {
                            ClickHaptics.selection()
                            onSkip()
                        }) {
                            Text(searched ? "Done" : "Skip for now")
                                .font(ClickTypography.labelLarge)
                                .foregroundStyle(ClickColors.textSecondary)
                                .padding(.vertical, ClickSpacing.sm)
                        }
                        .disabled(isSearching)
                    }
                    .padding(.horizontal, ClickSpacing.lg)
                    .padding(.bottom, ClickSpacing.xl)
                }
            }
        }
        .background(ClickColors.background.ignoresSafeArea())
    }

    private func discoverContacts() {
        ClickHaptics.impact(.medium)
        isSearching = true
        errorMessage = nil

        Task {
            let status = await PermissionCoordinator.shared.requestPermission(for: .contacts)
            guard status.isAuthorized else {
                isSearching = false
                searched = true
                errorMessage = "Contacts access was not granted. You can grant access in Settings."
                return
            }

            do {
                let hashes = try await ContactDiscoveryService.shared.collectAndHashDeviceContacts()
                let results = try await ContactDiscoveryService.shared.discoverMatches(hashes: hashes, client: env.api)
                matches = results
                searched = true
                ClickHaptics.success()
            } catch {
                errorMessage = "Failed to match contacts: \(error.localizedDescription)"
                searched = true
                ClickHaptics.error()
            }
            isSearching = false
        }
    }

    private func sendPriorRequest(to targetUserId: String) {
        ClickHaptics.impact(.light)
        requestedUserIds.insert(targetUserId)

        Task {
            do {
                try await ContactDiscoveryService.shared.requestPriorConnection(
                    targetUserId: targetUserId,
                    knownSince: knownSinceByUser[targetUserId] ?? .unspecified,
                    contextTag: nil,
                    client: env.api
                )
                ClickHaptics.success()
            } catch {
                requestedUserIds.remove(targetUserId)
                errorMessage = "Failed to send connection request. Try again."
                ClickHaptics.error()
            }
        }
    }
}
