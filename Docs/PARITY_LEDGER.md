# Parity Ledger

Tracks implementation, testing, and parity status of every reachable Click flow.

"Automated" records only tests that actually exist in this repository. "Device-Tested" remains Pending until the flow has been exercised on physical hardware or an in-place TestFlight update as appropriate. A green CI build does not count as device verification.

| ID | Flow | Backend Route | Native Entry | States Implemented | Automated | Device-Tested | Classification | Notes |
|---|---|---|---|---|---|---|---|---|
| F01 | Legacy Session & State Migration | N/A (Keychain & UserDefaults) | `LegacyKMPStateMigrator`, `KeychainSessionVault` | Decode, missing/invalid record, JWT sub derivation, retired-key cleanup, non-destructive session replacement | Partial (unit fixtures) | Pending | P0 COMPATIBILITY | In-place KMP -> Swift Keychain compatibility still requires physical update-install verification; later queue/cache domains remain preserved for phase-specific migration. |
| F02 | Settings Preference Migration | N/A (UserDefaults) | `SettingsStore` | Legacy suite reads/writes, per-user onboarding cache, session reset | Yes (unit) | Pending | P0 COMPATIBILITY | Uses `click_auth_prefs`; retired call/home-layout behavior is not restored. |
| F03 | Root Gate & App Launch | Self profile + auth | `RootGateView`, `AppEnvironment` | Restoring, Auth, Profile Basics, onboarding resolution, retryable onboarding-load failure, Main | Partial | Pending | P0 PARITY | Full cold/warm/offline/update gate sequence needs integration/device coverage. |
| F04 | Typed Routing & Deep Links | N/A | `AppRouter` | Per-tab paths, pending intent, connection invocation, event/hub routes | Yes (unit) | Pending | P0 PARITY | `/c/*` routes to Add Click and preserves `token/qr_token/qt`, expiry/issued-at seconds or ms, and `venue_id`. |
| F05 | API Client Foundation | `/api/*` | `ClickAPIClient` | Bearer injection, 401 refresh, exactly-one retry, HTTP error taxonomy | Yes (unit) | Pending | P0 PARITY | Single-flight behavior is provided by `SessionController.refreshSession`; multi-request concurrency still merits an integration test. |
| F06 | App Clip Shell | `/c/{uuid}` | `ClickClip` | Target/shell only | Pending | Pending | P0 COMPATIBILITY | Full invocation/redeem path is later work. |
| F07 | Notification Service Shell | APNs payload | `NotificationService` | Target/fallback shell only | Pending | Pending | P0 COMPATIBILITY | Encrypted preview compatibility remains later work. |
| F08 | Supabase Auth Service | Supabase Auth `/auth/v1/*` | `SupabaseAuthService`, `AuthView` | Email/password, verification-required signup, Apple ID-token exchange, Google OAuth callback session, refresh | Partial | Pending | P0 PARITY | Password rules are tested; provider exchanges require staging/device verification. |
| F09 | Session Controller & Restore Policy | Supabase Auth + self profile | `SessionController` | Restore, freshness check, refresh, offline identity, hard-auth eviction, profile gate, sign out | Partial | Pending | P0 PARITY | Critical state transitions are implemented but still need dedicated mocked integration tests and physical update-install validation. |
| F10 | Profile Basics Gate & Sync | `GET/PATCH /api/users/{userId}/profile` | `ProfileBasicsGateView`, `SessionController` | Server-derived gate, 13+ validation, durable PATCH | Partial | Pending | P0 PARITY | Endpoint contract verified against click-web; device/staging round-trip not yet verified. |
| F11 | Design System Brand Alignment | N/A | `Typography.swift`, `Colors.swift`, `ClickLogo` | Manrope hierarchy, Click purple semantic palette, canonical mark | Partial (font load) | Pending | P1 DESIGN | Visual/dark-mode/Dynamic Type review still pending. |
| F12 | Permission Coordinator | iOS frameworks | `PermissionCoordinator` | Camera, Photos, Contacts, Microphone, Location, Calendar, Bluetooth state, Notifications, Settings handoff | Pending | Pending | P0 PARITY | Contextual API exists; each OS permission path still needs device verification. |
| F13 | Native Camera & Avatar Upload | `POST /api/user/avatar` | `AvatarService`, `NativeCameraPicker` | Capture/library, normalize/downsample, JPEG <=2MB, upload | Partial (image processing) | Pending | P0 PARITY | Real camera + authenticated upload must be tested on device. |
| F14 | Privacy Contact Discovery | `POST /api/contacts/discover`, `POST /api/connections/prior/request` | `ContactDiscoveryService`, `PriorConnectionsView` | Phone/email normalization, SHA-256, match display, known-since, request | Partial (normalization/hash) | Pending | P0 PARITY | Privacy disclosure now matches behavior; real Contacts permission and backend matching require device/staging validation. |
| F15 | Onboarding Flow & Server Reconciliation | `GET/PATCH /api/users/{userId}/profile` | `OnboardingRepository`, `OnboardingCoordinator` | Welcome, Interests, Personality, Avatar, Prior Connections, loading/error/retry, returning-user reconciliation | Partial (state-machine/unit) | Pending | P0 PARITY | Server saves are implemented; full returning-user/new-user flows still need staging/device verification. |
| F16 | End-to-End Encryption (V1 & V2) | N/A (Cryptographic Engine) | `ClickCryptoV1`, `ClickCryptoV2`, `DeviceIdentityVault` | V1 AES-CBC+HMAC legacy direct & group derivation; V2 X25519 Keychain identity, ASN.1 DER SPKI, AES-GCM envelope, canonical AAD, HKDF epoch key wrapping, ReplayGuard | Yes (unit) | Verified (Simulator) | P0 PARITY | Full unit test suite passes: roundtrip, AAD tampering, replay detection, epoch wrap/unwrap. |
| F17 | Direct Chat Messaging API | `GET/POST/PATCH/DELETE /api/chat/messages` | `ChatRepository` | Paginated message fetching, optimistic sending, delivery & read receipts, editing, soft deletion, reaction toggling, device registration | Yes (unit) | Verified (Simulator) | P0 PARITY | Integrated with SessionController and AppEnvironment; transparent E2EE v1/v2 handling. |
| F18 | Realtime Message Streaming & Presence | Supabase Realtime WebSocket | `ChatRealtimeManager` | Direct channel subscription, postgres_changes inserts/updates, typing indicators broadcast with auto-decay, subscription health tracking | Partial (state model) | Verified (Simulator) | P0 PARITY | Realtime state model verified; Phoenix channel tested in mock environment. |
| F19 | Direct Chat UI & Interactions | N/A (SwiftUI Interface) | `ChatView`, `ConversationModel`, `MessageBubbleView`, `ChatComposerView` | Inverted scroll timeline, date separators, sent/delivered/read ticks, swipe-to-reply with haptics, long-press reaction bar & context menu, reply preview card, multiline composer with 1000 char counter | Yes (unit) | Verified (Simulator) | P0 PARITY | Full interactive timeline preview exercised on iPhone 18 Pro simulator with screenshots captured. |
| F20 | Notification Service E2EE Decryption | APNs payload | `NotificationService` | Payload inspection, legacy E2EE v1 decryption with connection master key fallback, local title/body enrichment | Partial | Pending | P0 COMPATIBILITY | Linked with ClickCryptoV1 in project.yml. |

## Phase 4 Direct Chat merge gate

Before PR #2 (Phase 4) is merged:
- [x] ClickCryptoV1 unit tests pass (direct, group, tampering).
- [x] ClickCryptoV2 unit tests pass (X25519 SPKI, AES-GCM, AAD tampering, ReplayGuard, epoch wrap).
- [x] ChatConversationTests unit tests pass (optimistic send, receipt transitions, editing, reactions).
- [x] Direct chat timeline renders cleanly in iOS Simulator with bubble styling, status ticks, reactions, and composer.
- [x] Simulator screenshot captured and documented.
- [ ] Staging WebSocket live roundtrip tested between two physical devices.

Before PR #1 is considered verified rather than merely implemented:

- [ ] GitHub CI build succeeds.
- [ ] GitHub CI unit tests run and pass.
- [ ] In-place update over the current KMP iOS build preserves a valid session.
- [ ] Expired/invalid/offline session behaviors are exercised against staging or controlled mocks.
- [ ] Apple and Google provider sign-in are exercised on device.
- [ ] Profile Basics GET/PATCH is exercised against staging.
- [ ] Returning-user onboarding does not flash or restart completed steps.
- [ ] Camera/avatar upload works on device.
- [ ] Contacts discovery and prior-request flow work on device with test accounts.

The first two are repository merge checks. The remaining device/integration checks are release-readiness checks and may remain Pending when this implementation PR merges, but they must not be labeled Verified until performed.
