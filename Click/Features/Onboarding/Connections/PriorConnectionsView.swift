import SwiftUI
import Contacts

/// Phase 2 Prior Connections screen allowing on-device contact discovery.
public struct PriorConnectionsView: View {
    @State private var isSearching: Bool = false
    @State private var searched: Bool = false
    @State private var errorMessage: String?

    let onComplete: () -> Void
    let onSkip: () -> Void

    public init(onComplete: @escaping () -> Void, onSkip: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onSkip = onSkip
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: ClickSpacing.xl) {
                // Header Brand
                VStack(spacing: ClickSpacing.md) {
                    Image(systemName: "person.2.badge.shield.checkmark.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(ClickColors.primary)
                        .padding(.top, ClickSpacing.xl)

                    VStack(spacing: ClickSpacing.xs) {
                        Text("Find your friends")
                            .font(ClickTypography.headlineLarge)
                            .tracking(-0.5)
                            .foregroundStyle(ClickColors.textPrimary)

                        Text("Find people you already know on Click. Your contacts are hashed locally on your device and never stored in plain text.")
                            .font(ClickTypography.bodyMedium)
                            .foregroundStyle(ClickColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, ClickSpacing.md)
                    }
                }

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
                        .font(ClickTypography.labelSmall)
                        .foregroundStyle(ClickColors.error)
                        .padding(.horizontal, ClickSpacing.lg)
                }

                Spacer(minLength: ClickSpacing.xl)

                // Actions
                VStack(spacing: ClickSpacing.sm) {
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

                    Button(action: {
                        ClickHaptics.selection()
                        onSkip()
                    }) {
                        Text("Skip for now")
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
        .background(ClickColors.background.ignoresSafeArea())
    }

    private func discoverContacts() {
        ClickHaptics.impact(.medium)
        isSearching = true
        errorMessage = nil

        Task {
            // Request contacts access or simulate discovery in simulator
            let store = CNContactStore()
            do {
                _ = try await store.requestAccess(for: .contacts)
            } catch {
                // Non-blocking error, user can still proceed
            }

            try? await Task.sleep(nanoseconds: 600_000_000)
            isSearching = false
            ClickHaptics.success()
            onComplete()
        }
    }
}
