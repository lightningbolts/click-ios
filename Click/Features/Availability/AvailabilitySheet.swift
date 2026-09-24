import SwiftUI

/// The canonical "I'm down for…" sheet, used from Home and Me (spec §64.1).
///
/// Share creates a server intent (`POST /api/user/availability-intents`) that expires on the
/// server; Remove deletes it. Nothing is shown as saved until the server confirms it.
struct AvailabilitySheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    /// Called after any successful change so the presenter can refresh its module.
    let onChanged: () -> Void

    @State private var intents = ModuleState<[AvailabilityIntentPost]>()
    @State private var tag = ""
    @State private var duration: AvailabilityDuration = .serverDefault
    @State private var isSharing = false
    @State private var removingID: String?
    @State private var errorMessage: String?
    @FocusState private var isTagFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Coffee, study, walk…", text: $tag)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .focused($isTagFocused)
                        .onChange(of: tag) { _, value in
                            if value.count > MeRepository.intentTagMaxLength {
                                tag = String(value.prefix(MeRepository.intentTagMaxLength))
                            }
                        }
                    Picker("For how long", selection: $duration) {
                        ForEach(AvailabilityDuration.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                } header: {
                    Text("What are you down for?")
                } footer: {
                    Text("Your Clicks see this until it expires. Connections with overlapping plans get a match alert.")
                }

                Section {
                    Button {
                        Task { await share() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSharing { ProgressView() } else { Text("Share availability") }
                            Spacer()
                        }
                    }
                    .disabled(cleanTag.isEmpty || isSharing)
                }

                activeSection

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .foregroundStyle(ClickColors.destructive)
                    }
                }
            }
            .navigationTitle("I'm down for…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var activeSection: some View {
        if let active = intents.value, !active.isEmpty {
            Section("Active now") {
                ForEach(active) { intent in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(intent.tag)
                            Text(AvailabilityFormatting.until(intent))
                                .font(ClickTypography.metadata)
                                .foregroundStyle(ClickColors.textSecondary)
                        }
                        Spacer()
                        if removingID == intent.id {
                            ProgressView()
                        } else {
                            Button("Remove", role: .destructive) {
                                Task { await remove(intent) }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        } else if intents.isPending {
            Section("Active now") {
                ProgressView()
            }
        } else if let message = intents.errorMessage {
            Section("Active now") {
                Button("Couldn't load your posts. \(message) Retry") {
                    Task { await load() }
                }
            }
        }
    }

    private var cleanTag: String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() async {
        guard let userID = env.session.currentSession?.userId else { return }
        intents.seed(await env.me.cachedIntents(userID: userID))
        intents.begin()
        do {
            intents.succeed(try await env.me.availabilityIntents(userID: userID))
        } catch {
            intents.fail(error.userFacingMessage)
        }
    }

    private func share() async {
        guard !cleanTag.isEmpty else { return }
        isSharing = true
        errorMessage = nil
        defer { isSharing = false }
        do {
            _ = try await env.me.createIntent(tag: cleanTag, duration: duration)
            ClickHaptics.success()
            tag = ""
            isTagFocused = false
            onChanged()
            await load()
        } catch {
            errorMessage = "Couldn't share availability. \(error.userFacingMessage)"
        }
    }

    private func remove(_ intent: AvailabilityIntentPost) async {
        removingID = intent.id
        errorMessage = nil
        defer { removingID = nil }
        do {
            try await env.me.deleteIntent(id: intent.id)
            onChanged()
            await load()
        } catch {
            errorMessage = "Couldn't remove that post. \(error.userFacingMessage)"
        }
    }
}

enum AvailabilityFormatting {
    /// "Until 9:30 PM" / "Until Thu 9:30 PM"; falls back to the server's timeframe label.
    static func until(_ intent: AvailabilityIntentPost, now: Date = .now) -> String {
        guard let expires = intent.expiresAt else { return intent.timeframe }
        let time = expires.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDate(expires, inSameDayAs: now) {
            return "Until \(time)"
        }
        return "Until \(expires.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }
}
