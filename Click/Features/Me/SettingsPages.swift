import SwiftUI

/// The single destination for typed `SettingsRoute`s.
struct SettingsPageView: View {
    let page: SettingsRoute

    var body: some View {
        switch page {
        case .alerts: AlertsSettingsView()
        case .privacy: PrivacySettingsView()
        case .permissions: PermissionsSettingsView()
        case .blocked: BlockedUsersView()
        case .interests: InterestsSettingsView()
        case .personality: PersonalitySettingsView()
        case .calendar: CalendarSettingsView()
        case .editProfile: EditProfileView()
        }
    }
}

// MARK: - Alerts

/// Server-backed push categories (spec §65.3). Each toggle stays in a pending state until the
/// server returns the saved row; a failure restores the previous value and says so.
struct AlertsSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    @State private var preferences = ModuleState<NotificationPreferences>()
    @State private var pendingKey: NotificationPreferences.Key?
    @State private var systemStatus: PermissionStatus?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            systemSection

            Section {
                if let prefs = preferences.value {
                    ForEach(NotificationPreferences.Key.allCases, id: \.self) { key in
                        Toggle(isOn: Binding(
                            get: { pendingKey == key ? !prefs[key] : prefs[key] },
                            set: { value in Task { await set(key, value) } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.title)
                                Text(key.detail)
                                    .font(ClickTypography.metadata)
                                    .foregroundStyle(ClickColors.textTertiary)
                            }
                        }
                        .disabled(pendingKey != nil)
                    }
                } else if preferences.isPending {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    Button("Couldn't load your notification settings. Retry") {
                        Task { await load() }
                    }
                }
            } header: {
                Text("Notify me about")
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(ClickColors.destructive)
                } else {
                    Text("These are saved to your account and control what Click sends to all your devices.")
                }
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { systemStatus = await env.permissions.statusAsync(for: .notifications) } }
        }
    }

    @ViewBuilder
    private var systemSection: some View {
        switch systemStatus {
        case .denied?, .restricted?:
            Section {
                Button("Turn on notifications in Settings") { env.permissions.openSystemSettings() }
            } footer: {
                Text("Notifications are off for Click in iOS Settings, so nothing below can reach this iPhone.")
            }
        case .notDetermined?:
            Section {
                Button("Allow notifications") {
                    Task { systemStatus = await env.permissions.requestPermission(for: .notifications) }
                }
            } footer: {
                Text("Allow notifications so the alerts you choose can reach this iPhone.")
            }
        default:
            EmptyView()
        }
    }

    private func load() async {
        guard let userID = env.session.currentSession?.userId else { return }
        systemStatus = await env.permissions.statusAsync(for: .notifications)
        preferences.begin()
        do {
            preferences.succeed(try await env.me.notificationPreferences(userID: userID))
        } catch {
            preferences.fail(error)
        }
    }

    private func set(_ key: NotificationPreferences.Key, _ enabled: Bool) async {
        pendingKey = key
        errorMessage = nil
        ClickHaptics.selection()
        defer { pendingKey = nil }
        do {
            let saved = try await env.me.setNotificationPreference(key, enabled: enabled)
            preferences.succeed(saved)
            if key == .messages { env.settings.messageNotificationsEnabled = saved[.messages] }
            if key == .eventReminders, !saved[.eventReminders] { await EventReminderScheduler.cancelAll() }
            if enabled, systemStatus == .notDetermined {
                systemStatus = await env.permissions.requestPermission(for: .notifications)
            }
        } catch {
            errorMessage = "\(key.title) wasn't changed. \(error.userFacingMessage)"
        }
    }
}

// MARK: - Privacy & data

/// The three independent location-privacy toggles (spec §65.4).
struct PrivacySettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var privacy = ModuleState<LocationPrivacy>()
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var locationHint: String?
    @State private var microphoneDenied = false

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section {
                if let value = privacy.value {
                    toggle("Location snap", "Save where you are when you Click with someone.", \.connectionSnap, value)
                    toggle("Memory Map", "Use your Click locations for your personal map and Remember Me.", \.memoryMap, value)
                    toggle("Business insights", "Include anonymized, aggregated visits in venue insights. Never identifies you.", \.businessInsights, value)
                } else if privacy.isPending {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    Button("Couldn't load your location settings. Retry") { Task { await load() } }
                }
            } header: {
                Text("Location")
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(ClickColors.destructive)
                } else if let locationHint {
                    Text(locationHint)
                } else {
                    Text("Each setting is independent and saved to your account.")
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { env.settings.ambientNoiseOptIn },
                    set: { value in Task { await setAmbient(value) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ambient sound")
                        Text("Adds a noise-level label to new encounters. Nothing is recorded or stored.")
                            .font(ClickTypography.metadata)
                            .foregroundStyle(ClickColors.textTertiary)
                    }
                }
                Toggle(isOn: $settings.barometricContextOptIn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Barometric context")
                        Text("Adds an elevation label to new encounters using this iPhone's barometer.")
                            .font(ClickTypography.metadata)
                            .foregroundStyle(ClickColors.textTertiary)
                    }
                }
            } header: {
                Text("Encounter context")
            } footer: {
                if microphoneDenied {
                    Button("Microphone access is off. Open Settings") { env.permissions.openSystemSettings() }
                        .font(ClickTypography.metadata)
                }
            }

            Section {
                NavigationLink(value: AppRoute.settings(.permissions)) {
                    Text("Permissions")
                }
                NavigationLink(value: AppRoute.settings(.blocked)) {
                    Text("Blocked people")
                }
            }
        }
        .navigationTitle("Privacy & data")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func toggle(
        _ title: String,
        _ detail: String,
        _ keyPath: WritableKeyPath<LocationPrivacy, Bool>,
        _ current: LocationPrivacy
    ) -> some View {
        Toggle(isOn: Binding(
            get: { current[keyPath: keyPath] },
            set: { value in
                var next = current
                next[keyPath: keyPath] = value
                Task { await save(next, enablingSnap: keyPath == \.connectionSnap && value) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textTertiary)
            }
        }
        .disabled(isSaving)
    }

    private func setAmbient(_ enabled: Bool) async {
        microphoneDenied = false
        guard enabled else {
            env.settings.ambientNoiseOptIn = false
            return
        }
        let status = env.permissions.status(for: .microphone)
        let resolved = status == .notDetermined ? await env.permissions.requestPermission(for: .microphone) : status
        if resolved == .authorized {
            env.settings.ambientNoiseOptIn = true
        } else {
            microphoneDenied = true
        }
    }

    private func load() async {
        guard let userID = env.session.currentSession?.userId else { return }
        privacy.begin()
        do {
            privacy.succeed(try await env.me.locationPrivacy(userID: userID))
        } catch {
            privacy.fail(error)
        }
    }

    private func save(_ next: LocationPrivacy, enablingSnap: Bool) async {
        guard let userID = env.session.currentSession?.userId else { return }
        isSaving = true
        errorMessage = nil
        locationHint = nil
        defer { isSaving = false }
        do {
            privacy.succeed(try await env.me.setLocationPrivacy(next, userID: userID))
        } catch {
            errorMessage = "Your location setting wasn't changed. \(error.userFacingMessage)"
            return
        }
        guard enablingSnap else { return }
        let status = env.permissions.status(for: .locationWhenInUse)
        let resolved = status == .notDetermined ? await env.permissions.requestPermission(for: .locationWhenInUse) : status
        if resolved != .authorized {
            locationHint = "Location snap is on, but location access is off for Click, so no location is saved. Turn it on in Permissions."
        }
    }
}

// MARK: - Blocked people

/// People the user blocked (`GET /api/safety/block`), with Unblock. Names come from the shared
/// identity cache; a failed load is shown as a failure, never as an empty list.
struct BlockedUsersView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppEnvironment.self) private var env

    @State private var blocked = ModuleState<[BlockedUser]>()
    @State private var names: [String: UserIdentity] = [:]
    @State private var unblocking: Set<String> = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let items = blocked.value {
                if items.isEmpty {
                    ContentUnavailableView("No one blocked", systemImage: "hand.raised", description: Text("People you block can't message you or see you on Click."))
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(items) { item in
                            row(item)
                        }
                    } footer: {
                        if let errorMessage { Text(errorMessage).foregroundStyle(ClickColors.destructive) }
                    }
                }
            } else if blocked.isPending {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else {
                Button("Couldn't load blocked people. Retry") { Task { await load() } }
            }
        }
        .navigationTitle("Blocked people")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ item: BlockedUser) -> some View {
        let identity = names[item.userID]
        // Accessibility text sizes stack the Unblock button under the name instead of squeezing it.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            AvatarView(imageURL: identity?.avatarURL, seed: item.userID, initials: String((identity?.name ?? "?").prefix(1)), size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(identity?.name ?? "Click user")
                    .font(ClickTypography.body)
                if let date = item.blockedAt {
                    Text("Blocked \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(ClickTypography.metadata)
                        .foregroundStyle(ClickColors.textTertiary)
                }
            }
            Spacer()
            Button("Unblock") { Task { await unblock(item) } }
                .buttonStyle(.bordered)
                .disabled(unblocking.contains(item.userID))
                .accessibilityLabel("Unblock \(identity?.name ?? "this person")")
        }
    }

    private func load() async {
        blocked.begin()
        do {
            let items = try await env.profiles.blockedUsers()
            blocked.succeed(items)
            names = await env.identities.resolve(items.map(\.userID))
        } catch {
            blocked.fail(error)
        }
    }

    private func unblock(_ item: BlockedUser) async {
        unblocking.insert(item.userID)
        defer { unblocking.remove(item.userID) }
        do {
            try await env.profiles.unblock(userID: item.userID)
            blocked.succeed((blocked.value ?? []).filter { $0.userID != item.userID })
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't unblock. \(error.userFacingMessage)"
        }
    }
}

// MARK: - Permissions hub

/// Current platform authorization for every capability Click uses (spec §65.11).
struct PermissionsSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var statuses: [PermissionType: PermissionStatus] = [:]

    private let rows: [(PermissionType, String, String, String)] = [
        (.locationWhenInUse, "Location", "location", "Map, Tap to Connect, event check-in"),
        (.bluetooth, "Bluetooth", "dot.radiowaves.left.and.right", "Tap to Connect"),
        (.microphone, "Microphone", "mic", "Tap to Connect sound check, voice notes"),
        (.camera, "Camera", "camera", "QR scanning, photos"),
        (.photoLibrary, "Photos", "photo", "Sharing and saving photos"),
        (.contacts, "Contacts", "person.crop.circle", "Finding people you know (hashed on this iPhone)"),
        (.calendar, "Calendar", "calendar", "Free/busy for availability"),
        (.notifications, "Notifications", "bell", "Messages and alerts")
    ]

    var body: some View {
        Form {
            Section {
                ForEach(rows, id: \.1) { type, title, symbol, use in
                    HStack(spacing: 14) {
                        Image(systemName: symbol).frame(width: 28).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                            Text(use)
                                .font(ClickTypography.metadata)
                                .foregroundStyle(ClickColors.textTertiary)
                        }
                        Spacer()
                        action(for: type)
                    }
                }
            } footer: {
                Text("Click asks for access only when you use a feature that needs it.")
            }
        }
        .navigationTitle("Permissions")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    @ViewBuilder
    private func action(for type: PermissionType) -> some View {
        switch statuses[type] {
        case .authorized?:
            Text("Allowed").foregroundStyle(ClickColors.textTertiary)
        case .notDetermined? where type != .bluetooth:
            Button("Allow") {
                Task {
                    statuses[type] = await env.permissions.requestPermission(for: type)
                }
            }
            .buttonStyle(.borderless)
        case nil:
            ProgressView()
        default:
            Button(statuses[type] == .notDetermined ? "Not asked" : "Settings") {
                env.permissions.openSystemSettings()
            }
            .buttonStyle(.borderless)
        }
    }

    private func refresh() async {
        for (type, _, _, _) in rows {
            statuses[type] = await env.permissions.statusAsync(for: type)
        }
    }
}

// MARK: - Interests / Personality

/// Edits the same `user_interests.tags` the onboarding step writes (spec §65.5).
struct InterestsSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var profile = ModuleState<SelfProfile>()

    var body: some View {
        Group {
            if let current = profile.value {
                InterestsPickerView(
                    initialTags: current.interests,
                    initialExpandedCategories: [],
                    title: "Your interests",
                    actionTitle: "Save"
                ) { tags in
                    try await env.onboardingRepository.saveInterests(userId: current.userID, tags: tags)
                    await persist(current.with(interests: tags))
                    dismiss()
                }
            } else {
                SelfProfileLoadingView(state: profile) { await load() }
            }
        }
        .navigationTitle("Interests")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        await SelfProfileLoader.load(into: $profile, env: env)
    }

    private func persist(_ updated: SelfProfile) async {
        await CacheStore.shared.save(updated, key: "self-profile", userID: updated.userID)
    }
}

/// Edits the exactly-5 personality traits (spec §65.6, helper copy "Pick exactly 5 traits.").
struct PersonalitySettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var profile = ModuleState<SelfProfile>()

    var body: some View {
        Group {
            if let current = profile.value {
                PersonalityTaggingView(
                    initialTraits: current.personality,
                    title: "Your personality",
                    subtitle: "Pick exactly 5 traits.",
                    actionTitle: "Save"
                ) { traits in
                    try await env.onboardingRepository.savePersonality(userId: current.userID, traits: traits)
                    await CacheStore.shared.save(current.with(personality: traits), key: "self-profile", userID: current.userID)
                    dismiss()
                }
            } else {
                SelfProfileLoadingView(state: profile) { await SelfProfileLoader.load(into: $profile, env: env) }
            }
        }
        .navigationTitle("Personality")
        .navigationBarTitleDisplayMode(.inline)
        .task { await SelfProfileLoader.load(into: $profile, env: env) }
    }
}

/// Editors must start from server truth — never an empty selection that would overwrite it.
enum SelfProfileLoader {
    @MainActor
    static func load(into state: Binding<ModuleState<SelfProfile>>, env: AppEnvironment) async {
        guard let userID = env.session.currentSession?.userId else { return }
        state.wrappedValue.begin()
        do {
            state.wrappedValue.succeed(try await env.me.selfProfile(userID: userID))
        } catch {
            state.wrappedValue.fail(error)
        }
    }
}

struct SelfProfileLoadingView: View {
    let state: ModuleState<SelfProfile>
    let retry: () async -> Void

    var body: some View {
        if let message = state.errorMessage {
            ContentUnavailableView {
                Label("Couldn't load your profile", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await retry() } }
            }
        } else {
            ProgressView()
        }
    }
}

// MARK: - Calendar

/// Read-only calendar access for free/busy (spec §81). Click never creates or edits events.
struct CalendarSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: PermissionStatus?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Calendar access")
                    Spacer()
                    switch status {
                    case .authorized?:
                        Text("Allowed").foregroundStyle(ClickColors.textTertiary)
                    case .notDetermined?:
                        Button("Allow") {
                            Task { status = await env.permissions.requestPermission(for: .calendar) }
                        }
                        .buttonStyle(.borderless)
                    case nil:
                        ProgressView()
                    default:
                        Button("Settings") { env.permissions.openSystemSettings() }
                            .buttonStyle(.borderless)
                    }
                }
            } footer: {
                Text("Click reads only busy and free times on this iPhone for availability. Event titles, locations, and attendees never leave your device, and Click never adds or changes calendar events.")
            }
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .task { status = env.permissions.status(for: .calendar) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { status = env.permissions.status(for: .calendar) }
        }
    }
}

// MARK: - Edit profile

struct EditProfileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var profile = ModuleState<SelfProfile>()
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var bio = ""
    @State private var isSaving = false
    @State private var removingPhoto = false
    @State private var confirmRemovePhoto = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if let value = profile.value {
                Section("Name") {
                    TextField("First name", text: $firstName)
                        .textContentType(.givenName)
                    TextField("Last name", text: $lastName)
                        .textContentType(.familyName)
                }
                Section {
                    TextField("A line about you", text: $bio, axis: .vertical)
                        .lineLimit(2...4)
                        .onChange(of: bio) { _, next in
                            if next.count > MeRepository.bioMaxLength { bio = String(next.prefix(MeRepository.bioMaxLength)) }
                        }
                } header: {
                    Text("Bio")
                } footer: {
                    Text("\(bio.count)/\(MeRepository.bioMaxLength) · Shown on your profile to people you've Clicked with.")
                }
                if value.avatarURL != nil {
                    Section {
                        Button(removingPhoto ? "Removing…" : "Remove photo", role: .destructive) { confirmRemovePhoto = true }
                            .disabled(removingPhoto)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(ClickColors.destructive)
                    }
                }
            } else {
                SelfProfileLoadingView(state: profile) { await load() }
            }
        }
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove your photo?", isPresented: $confirmRemovePhoto, titleVisibility: .visible) {
            Button("Remove photo", role: .destructive) { Task { await removePhoto() } }
        } message: {
            Text("People will see your initials instead.")
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save() } }
                        .disabled(firstName.trimmingCharacters(in: .whitespaces).isEmpty || profile.value == nil)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        await SelfProfileLoader.load(into: $profile, env: env)
        if let value = profile.value {
            firstName = value.firstName
            lastName = value.lastName
            bio = value.bio ?? ""
        }
    }

    private func removePhoto() async {
        guard let userID = env.session.currentSession?.userId else { return }
        removingPhoto = true
        defer { removingPhoto = false }
        do {
            try await env.me.removeAvatar(userID: userID)
            if let refreshed = try? await env.me.selfProfile(userID: userID) { profile.succeed(refreshed) }
            ClickHaptics.success()
        } catch {
            errorMessage = "Your photo wasn't removed. \(error.userFacingMessage)"
        }
    }

    private func save() async {
        guard let userID = env.session.currentSession?.userId else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await env.me.updateProfile(userID: userID, fields: [
                "first_name": firstName.trimmingCharacters(in: .whitespacesAndNewlines),
                "last_name": lastName.trimmingCharacters(in: .whitespacesAndNewlines),
                "bio": bio.trimmingCharacters(in: .whitespacesAndNewlines)
            ])
            _ = try? await env.me.selfProfile(userID: userID)
            ClickHaptics.success()
            dismiss()
        } catch {
            errorMessage = "Your profile wasn't saved. \(error.userFacingMessage)"
        }
    }
}
