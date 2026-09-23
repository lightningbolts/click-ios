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
                                .foregroundStyle(ClickColors.accentForeground)
                            Text("Privacy-Preserving Contact Matching")
                                .font(ClickTypography.supportingEmphasized)
                                .fontWeight(.semibold)
                                .foregroundStyle(ClickColors.textPrimary)
                        }

                        Text("Click reads phone numbers and email addresses from your address book on this device, normalizes and hashes them locally with SHA-256, and uploads only those hashes for matching. Plaintext contact details are never uploaded or stored by Click.")
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textSecondary)
                            .lineSpacing(2)
                    }
                    .padding(ClickSpacing.md)
                    .background(ClickColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: ClickRadius.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: ClickRadius.surface)
                            .stroke(ClickColors.separator, lineWidth: ClickMetrics.strokeWidth)
                    )
                    .padding(.horizontal, ClickSpacing.lg)

                    if let error = errorMessage {
                        Text(error)
                            .font(ClickTypography.metadata)
                            .foregroundStyle(ClickColors.destructive)
                            .padding(.horizontal, ClickSpacing.lg)
                    }

                    // Matches List (when searched)
                    if searched {
                        if matches.isEmpty {
                            VStack(spacing: ClickSpacing.xs) {
                                Image(systemName: "person.2.slash")
                                    .font(.system(size: 36))
                                    .foregroundStyle(ClickColors.textTertiary)
                                    .padding(.top, ClickSpacing.md)

                                Text("No friends found yet")
                                    .font(ClickTypography.supportingEmphasized)
                                    .foregroundStyle(ClickColors.textPrimary)

                                Text("None of your contacts are on Click yet. You can always connect in person via QR or Tap.")
                                    .font(ClickTypography.supporting)
                                    .foregroundStyle(ClickColors.textSecondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, ClickSpacing.lg)
                            }
                            .padding(.vertical, ClickSpacing.md)
                        } else {
                            VStack(alignment: .leading, spacing: ClickSpacing.sm) {
                                Text("Suggested Friends (\(matches.count))")
                                    .font(ClickTypography.supportingEmphasized)
                                    .foregroundStyle(ClickColors.textSecondary)
                                    .padding(.horizontal, ClickSpacing.lg)

                                ForEach(matches) { match in
                                    HStack(spacing: ClickSpacing.md) {
                                        Circle()
                                            .fill(ClickColors.surface)
                                            .frame(width: 44, height: 44)
                                            .overlay(
                                                Text(match.name.prefix(1))
                                                    .font(ClickTypography.supportingEmphasized)
                                                    .foregroundStyle(ClickColors.accentForeground)
                                            )

                                        VStack(alignment: .leading, spacing: ClickSpacing.xxs) {
                                            Text(match.name)
                                                .font(ClickTypography.supportingEmphasized)
                                                .foregroundStyle(ClickColors.textPrimary)

                                            if !match.tags.isEmpty {
                                                Text(match.tags.prefix(2).joined(separator: ", "))
                                                    .font(ClickTypography.metadata)
                                                    .foregroundStyle(ClickColors.textSecondary)
                                            }

                                            Menu {
                                                ForEach(PriorKnownSince.allCases) { option in
                                                    Button(option.label) {
                                                        knownSinceByUser[match.id] = option
                                                    }
                                                }
                                            } label: {
                                                HStack(spacing: ClickSpacing.xxs) {
                                                    Text("Known since: \((knownSinceByUser[match.id] ?? .unspecified).label)")
                                                        .font(ClickTypography.metadata)
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
                                                .font(ClickTypography.supportingEmphasized)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 7)
                                                .background(isRequested ? ClickColors.fillSubtle : ClickColors.primaryActionFill)
                                                .foregroundStyle(isRequested ? ClickColors.textSecondary : ClickColors.primaryActionForeground)
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
                                        Text("Discovering friends…")
                                    } else {
                                        Image(systemName: "person.crop.circle.badge.plus")
                                        Text("Find Friends from Contacts")
                                    }
                                }
                            }
                            .buttonStyle(.clickPrimary)
                            .disabled(isSearching)
                        } else {
                            Button("Continue", action: onComplete)
                                .buttonStyle(.clickPrimary)
                        }

                        Button(action: {
                            ClickHaptics.selection()
                            onSkip()
                        }) {
                            Text(searched ? "Done" : "Skip for now")
                                .font(ClickTypography.bodyEmphasized)
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
            let status = await env.permissions.requestPermission(for: .contacts)
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
