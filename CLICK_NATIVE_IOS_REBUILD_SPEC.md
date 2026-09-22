# Click Native iOS Rebuild Specification

**Repository:** `click-ios`  
**Product:** Click Platforms / Click  
**Purpose:** Replace the existing Kotlin Multiplatform iOS presentation/client implementation with a clean native Swift iOS application while preserving the existing Click backend, user accounts, App Store identity, data model, encryption compatibility, deep links, App Clip, push behavior, and product semantics.  
**Status:** Implementation specification  
**Primary implementation target:** Native iOS, Swift + SwiftUI, with UIKit / native Apple frameworks only where SwiftUI does not expose the required platform behavior cleanly.  
**Existing Android client:** Remains in `click`; this project does not rewrite Android.  
**Existing web/backend:** Remains in `click-web` / Supabase and is the authoritative server/business-rule layer.  
**New repository:** `lightningbolts/click-ios`  
**Baseline reviewed:** `click`, `click-web`, `click-split-app`, and current mobile regression/UI documentation as of September 2026.

---

# 0. Executive directive

This is **not** a line-by-line port of the current KMP iOS code. It is a clean native client replacement.

The existing `click` repository serves as the **behavioral and compatibility reference**: it tells us what users can do today, which edge cases already exist, what data must remain readable, and which backend flows are already integrated.

The `click-web` repository and the Supabase schema/functions it owns serve as the **authoritative backend contract**. Server-authoritative rules must not be reimplemented independently in Swift when a server API, RPC, RLS policy, Edge Function, or shared backend rule already exists.

The `click-split-app` repository serves as a **native architecture reference**, not as a codebase to merge with. Its useful patterns include SwiftUI-first rendering, `Observation`, a small dependency environment, feature-local observable state, typed routing, Swift concurrency, native sheets/navigation, and thin repository layers. Do not create a shared Swift package between Click Split and Click merely because similar code exists. Duplication is preferable to an incorrect shared abstraction during the initial rebuild.

The new client must feel like a high-quality iOS application because it **is** an iOS application. Native navigation, native scrolling, native gestures, native keyboard behavior, native sheets, native presentation transitions, native haptics, native accessibility, native menus, native system material, native photo/camera/file pickers, and native lifecycle APIs are the default. Custom emulation of system interaction should be treated as an exception requiring justification.

The replacement must be releasable as an **update to the existing App Store product**, not as a second product.

---

# 1. Requirement classification

Every requirement in this document is assigned one of these semantics.

| Classification | Meaning |
|---|---|
| **P0 — PARITY** | Required before `click-ios` can replace the current iOS app. Existing users must not lose this reachable behavior. |
| **P0 — COMPATIBILITY** | Required to preserve existing sessions, data, encryption, links, push behavior, App Store identity, or backend interoperability. |
| **P1 — QUALITY** | Required for the native rebuild to achieve its reason for existing: substantially better responsiveness, animation coherence, and iOS behavior. |
| **P1 — HARDENING** | Required before production cutover because the old client exposed fragility here. |
| **P2 — NEW NATIVE** | Backend/product capability exists but is not a current mobile parity blocker; implement after the core replacement is stable. |
| **AUDIT BEFORE SURFACING** | Code/data exists, but current reachability or intended product status is unclear. Do not expose a UI merely because an old screen exists. |
| **REMOVE / DO NOT PORT** | Explicitly retired behavior. It must not accidentally return during the rewrite. |
| **LEGACY READ COMPATIBILITY** | Old data must remain readable, but new writes should use the current protocol. |

The implementation agent must never infer that "code exists" means "feature should be surfaced." Reachability and current product intent matter.

---

# 2. Source-of-truth precedence

When current sources disagree, use this precedence order:

1. **Current authoritative repo guidance and current production code**
   - `click/AI.md`
   - current `click` main branch runtime code
   - current `click-web` main branch runtime code
   - current database migrations / Edge Functions / API authorization rules
2. **Current backend contract documentation**
   - `click-web/lib/*/README.md`
   - current API route source
   - current Supabase schema/migrations
3. **Current regression and September stabilization documentation**
   - `click/docs/regression-testing/*`
   - September 2026 polish/refinement/review documents
4. **Current feature blueprints**
   - `click/docs/ui-ux/mobile/*`
5. **Archived handoffs / historical documents**
   - use only to understand why behavior exists; never override current code
6. **Model assumptions**
   - never use when the repository can answer the question

Known contradiction that is already resolved:

> **Voice/video calls are removed from mobile.**  
> Do not add LiveKit, CallKit, PushKit, VoIP notification handling, call overlays, call settings, or call buttons. Older docs and stale regression rows mentioning calls are historical. `click/AI.md` is authoritative.

Another distinction that must remain explicit:

> **Ticketed events are implemented at the backend layer but are not current KMP mobile parity.**  
> Ticketing belongs in the native roadmap as P2 new-native work unless product scope is deliberately advanced during implementation.

---

# 3. Repositories and ownership boundaries

## 3.1 `click-ios` — new native client

Owns:

- SwiftUI presentation
- iOS navigation and routing
- iOS gesture behavior
- iOS keyboard behavior
- local app/session presentation state
- local caches and queued client work
- Apple platform integrations
- APNs registration and notification routing
- Notification Service Extension
- App Clip
- CoreBluetooth / audio / Core Location proximity sensing
- camera/photo/file/audio input
- MapKit/native map presentation unless a backend-specific map requirement makes another renderer necessary
- native E2EE implementation compatible with Click protocols
- local media vault/decryption
- accessibility and haptics
- performance instrumentation
- iOS-specific offline recovery

Does **not** own:

- cross-client business truth
- connection authorization policy
- event attendance truth
- ticket settlement
- pricing
- payment fulfillment
- server-side proximity validation rules
- chat membership authorization
- server-side push recipient resolution
- analytics aggregation rules
- RLS policy
- durable database migrations

## 3.2 `click-web` — backend/BFF authority

Use `click-web` for server-authoritative operations, particularly where a mutation:

- uses service-role credentials,
- applies business rules,
- joins multiple tables,
- performs authorization beyond ordinary RLS,
- mints/redeems tokens,
- coordinates a transaction,
- controls event/hub attendance,
- applies lifecycle state,
- creates or validates multi-user graph structures,
- creates payment/ticket state,
- generates signed asset access,
- or sends notifications.

The native app should generally call typed HTTP endpoints in `click-web` rather than duplicating a mutation through direct PostgREST.

## 3.3 Supabase — platform substrate

The native app may use Supabase directly for capabilities where doing so is already part of the intended architecture and does not duplicate business logic:

- authentication/session,
- realtime channels,
- presence/typing,
- authorized storage transport where the protocol requires it,
- safe read models under RLS,
- explicitly approved RPCs.

All direct table mutations must be reviewed. "It is easy to insert this row from Swift" is not sufficient justification.

## 3.4 `click` — compatibility oracle

Do not depend on Kotlin at runtime from `click-ios`.

Use `click` to answer:

- What does this flow currently do?
- Which backend route is called?
- Which local/offline states exist?
- Which edge cases have already been discovered?
- Which wire formats must remain readable?
- Which entitlement or permission is required?
- Which current behavior is retired?
- Which product copy is current?
- Which regression must be preserved?

Android continues to live here independently.

## 3.5 `click-split-app` — architectural reference only

Patterns worth retaining:

- `@Observable` app environment
- `@Observable` router
- feature-local observable models
- simple protocol-backed repositories
- Swift concurrency
- no giant Redux/global presentation store
- native SwiftUI surfaces
- isolated design tokens
- isolated haptic/motion primitives
- thin API clients

Patterns that must **not** be copied blindly:

- simple auth token handling that does not match Click's mature refresh/rebind requirements
- direct table mutation where Click already has BFF authorization/business logic
- Click Split financial/product models
- any visual design specific to Click Split
- any package structure that does not fit Click's larger feature graph

---

# 4. Apple platform identity preservation — P0 COMPATIBILITY

The new repository creates a new Xcode project, **not** a new App Store product.

## 4.1 Existing identity values to preserve

Current values from `click`:

| Item | Preserve |
|---|---|
| App Store Connect app | Existing Click Platforms / Click record |
| Apple Developer Team | `W4C3V9Z2N4` |
| Main bundle identifier | `compose.project.click.click` |
| Existing product identity | same App Store application |
| Existing custom URL scheme | `click://` |
| Existing associated domains | `applinks:joinclick.co`, `applinks:www.joinclick.co`, `applinks:click-us.vercel.app` |
| Sign in with Apple capability | yes |
| Push Notifications | yes, standard APNs |
| App Clip bundle ID | `compose.project.click.click.Clip` |
| Notification Service bundle ID | `compose.project.click.click.NotificationService` |
| Minimum iOS baseline | preserve iOS 18.2 unless product deliberately changes support |
| Encryption export declaration | preserve reviewed behavior; current app declares `ITSAppUsesNonExemptEncryption = false` |

The new project's marketing/build version must continue from App Store Connect/TestFlight versioning. Do not reset versioning simply because the source repository changed.

## 4.2 Main app entitlements

Recreate and verify:

```text
aps-environment
com.apple.developer.applesignin = Default
com.apple.developer.associated-domains:
  applinks:joinclick.co
  applinks:www.joinclick.co
  applinks:click-us.vercel.app
com.apple.developer.associated-appclip-app-identifiers:
  $(AppIdentifierPrefix)compose.project.click.click.Clip
```

Do not add VoIP/PushKit capabilities.

## 4.3 Main Info.plist/platform declarations

Preserve the capabilities that are actually used, while removing stale permission copy from retired features.

Current native requirements include:

- `NSBluetoothAlwaysUsageDescription`
- `NSMicrophoneUsageDescription` — copy must describe Tap-to-Connect ultrasonic sensing and voice notes, **not removed voice/video calls**
- `NSCalendarsFullAccessUsageDescription` / deployment-target-appropriate read-access copy for the read-only availability feature
- `NSContactsUsageDescription`
- `NSLocationWhenInUseUsageDescription`
- `NSCameraUsageDescription`
- `NSPhotoLibraryUsageDescription`
- `NSPhotoLibraryAddUsageDescription`
- `NSMotionUsageDescription` — current hardware-vibe/relative-height context uses Core Motion where available

Current iOS location code requests **When In Use** authorization. Do not request Always location or add background-location capability merely because an old Xcode build setting contains an `NSLocationAlwaysAndWhenInUseUsageDescription` string; no current `requestAlwaysAuthorization()` call was found.

Do **not** add `NFCReaderUsageDescription` or an NFC entitlement (§110).
- URL scheme `click`
- Google OAuth reversed client URL scheme for the existing iOS OAuth client

Current Google IDs in the existing iOS build:

```text
GIDClientID:
530817233802-crnehf5a9duauov4vos4lgsijkgingdj.apps.googleusercontent.com

GIDServerClientID:
530817233802-3ki7usecs885vvag9uq92ubu5hgkv2sp.apps.googleusercontent.com
```

The reversed iOS client scheme must remain registered unless the Google OAuth configuration is deliberately migrated server-side/App-Console-side first.

- `UIBackgroundModes`
  - `remote-notification`
  - `bluetooth-central`
  - `bluetooth-peripheral`
  - `audio` only if the ultrasonic/background audio behavior truly requires it after native implementation review
- `CADisableMinimumFrameDurationOnPhone = true` unless current SDK behavior makes it obsolete
- current full-screen/product requirements

Permission copy must describe the **actual** behavior. Do not retain stale mention of removed calls. Microphone copy should describe Tap-to-Connect ultrasonic sensing and voice notes if voice notes remain.

## 4.4 App Clip

Create a `ClickClip` target in `click-ios` using the existing bundle identity.

Required:

- bundle: `compose.project.click.click.Clip`
- parent: `$(AppIdentifierPrefix)compose.project.click.click`
- on-demand install capability
- associated App Clip domains:
  - `appclips:joinclick.co`
  - `appclips:www.joinclick.co`
  - `appclips:click-us.vercel.app`
- parse the current Click connection invocation URL
- load public profile/connection context
- continue the supported App Clip handshake path
- handle malformed/expired invocation safely
- never become a divergent second connection protocol

The App Clip must use shared source files/packages from `click-ios` where size and entitlement constraints allow, but its dependency graph must remain deliberately small.

## 4.5 Notification Service Extension

Create `NotificationService` target with:

- bundle: `compose.project.click.click.NotificationService`
- existing APNs extension point
- compatibility with encrypted push previews
- no dependency on full app UI
- deterministic fallback copy when decryption cannot occur

Crypto code shared between the main app and extension must be placed in a small pure-Swift module/target whose dependency graph is safe for extensions.

---

# 5. Seamless migration from the KMP iOS app — P0 COMPATIBILITY

A user updating from the existing TestFlight/App Store build must not be treated like a first-time install merely because the implementation language changed.

## 5.1 Existing secure session record

Current KMP iOS token storage uses:

```text
Keychain generic password
service: com.click.auth
account: session_v2
accessibility: WhenUnlockedThisDeviceOnly
```

Payload is JSON equivalent to:

```json
{
  "version": 2,
  "jwt": "...",
  "refreshToken": "...",
  "expiresAt": 0,
  "tokenType": "...",
  "userId": "..."
}
```

The new app must implement `LegacyKMPStateMigrator` and attempt this import before showing authentication.

Rules:

1. Read `service=com.click.auth`, `account=session_v2`.
2. Decode version 2 leniently.
3. Require non-empty access and refresh tokens.
4. Import into the new session store / official Supabase session representation.
5. Immediately perform the normal session validation/refresh path.
6. Only after a valid new session has been persisted should any obsolete duplicate representation be deleted.
7. If refresh token is invalid, gracefully route to login; never loop forever on boot.
8. Never log tokens or raw Keychain payloads.
9. Migration must be idempotent.
10. Unit-test with golden legacy JSON.

Using the same bundle ID/team should preserve default Keychain access, but the migration code must still target the old service/account explicitly.

## 5.2 Existing UserDefaults suite

Current KMP iOS uses suite:

```text
click_auth_prefs
```

Known keys:

```text
free_this_week
tags_initialized
dark_mode_enabled
home_layout_mode
message_notifications_enabled
call_notifications_enabled            # stale/retired; do not surface call settings
ambient_noise_opt_in
barometric_context_opt_in
location_explainer_seen
onboarding_state
has_completed_onboarding
cached_app_snapshot
pending_connection_queue
pending_proximity_handshake_queue
active_hubs
beacon_rsvp_snapshot
beacon_engagement_snapshot
```

Migration policy:

- import useful preferences where still valid;
- ignore/retire `call_notifications_enabled`;
- ignore retired `home_layout_mode` for product behavior; current Home is linear-only even if an old installation stored `PILE`;
- import onboarding state only as an optimization, then reconcile against server truth;
- attempt to decode queued connections/proximity handshakes and either migrate them to the new queue schema or preserve them until a compatibility sync flush succeeds;
- import cached app data only if its schema can be decoded safely; otherwise discard cache and refetch;
- import hub/RSVP/engagement snapshots as temporary offline state only, then reconcile from the server;
- never treat migrated cache as server truth;
- set a local `legacy_kmp_migration_completed` marker only after all independently recoverable migrations have been attempted;
- migration failure for a nonessential cache must not log the user out.

## 5.3 Existing crypto identity

The E2EE v2 implementation uses a device-bound X25519 private identity stored in iOS Keychain with `ThisDeviceOnly` / `WhenUnlocked`.

Current KMP iOS coordinates are now verified:

```text
Keychain generic password
service: com.click.e2ee.v2
account: x25519_identity_private_key
value: exactly 32 raw private-key bytes
accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
device_id: SHA-256(SPKI(X25519 public key)), lowercase hex
```

The Swift client must **reuse this exact private identity** on an in-place update. It may either read the existing record in place or migrate it transactionally into a new secure representation, but it must not generate a replacement identity merely because the implementation language changed. Generating a new device identity without coordinating the existing server-side device/key-transfer protocol can strand historical v2 messages.

This is a release blocker.

Required migration tests:

- legacy v1 direct message decrypt
- legacy v1 group message decrypt
- existing v2 direct epoch decrypt after app update
- existing v2 group/clique epoch decrypt after app update
- existing v2 event-hub epoch decrypt after app update
- encrypted attachment decrypt
- Notification Service preview behavior after update
- logout wipes in-memory epoch keys and the intended session-scoped caches without accidentally deleting durable device identity unless the current security protocol requires that

## 5.4 Existing push token

On first authenticated launch:

- register for remote notifications according to the current preference/permission state;
- upload/upsert the current APNs token;
- tolerate duplicate/upsert semantics;
- do not assume the previous binary's registration remains sufficient forever.

---

# 6. Technology decisions

## 6.1 Language and UI

- Swift 6 language mode or current stable equivalent supported by the project toolchain.
- SwiftUI for normal UI.
- UIKit wrappers only where Apple-native behavior is unavailable or measurably inferior in SwiftUI.
- `Observation` (`@Observable`) for feature/app presentation state.
- Structured concurrency (`async/await`, actors, task groups where justified).
- Foundation `URLSession` for `click-web` HTTP.
- An isolated Supabase adapter for auth/realtime/storage. Prefer the maintained native Supabase Swift SDK behind protocols rather than spreading SDK types throughout features.
- CryptoKit / Security / CommonCrypto only behind a small audited crypto layer.
- CoreBluetooth for BLE.
- AVFoundation / AVAudioEngine for ultrasonic sensing and voice recording.
- CoreLocation for location.
- PhotosUI / PHPicker where appropriate.
- AVFoundation camera pipeline or system scanner APIs for QR/capture as appropriate.
- EventKit for calendar features.
- Contacts framework for Prior Connections hashing.
- UserNotifications for APNs.
- MapKit/native Apple map stack unless a documented map behavior cannot be achieved without another renderer.

Do not add a third-party UI framework to imitate platform behavior.

## 6.2 Dependency rule

A dependency is allowed only when at least one is true:

- it implements a protocol that is expensive/security-sensitive to maintain internally;
- it is the official provider SDK for a backend Click already uses;
- it materially reduces implementation/security risk;
- it is required by an auth/payment/vendor integration.

Do not add libraries for:

- routing,
- observable state,
- basic animations,
- networking wrappers,
- image cards,
- bottom sheets,
- haptics,
- button styling,
- generic "clean architecture",
- dependency injection containers.

## 6.3 No speculative abstraction

Hard rules:

- no `BaseViewModel`;
- no `BaseRepository`;
- no generic route factory;
- no custom navigation framework;
- no service locator;
- no "Manager" that owns unrelated domains;
- no single global `AppState` containing every feature;
- no direct backend calls from SwiftUI `body`;
- no API DTO reused as mutable view state;
- no business policy inside a view;
- no one-off avatar implementations;
- no one-off media viewers;
- no separate chat implementations for DM/group when behavior can be parameterized naturally;
- no separate event detail implementations by entry point;
- no separate profile implementations by entry point;
- no custom gesture recognizer layered over scroll views unless the system gesture cannot fulfill the product interaction.

Wait until at least two or three real use cases justify extraction.

---

# 7. Proposed repository layout

```text
click-ios/
├── README.md
├── AI.md
├── CLICK_NATIVE_IOS_REBUILD_SPEC.md
├── Click.xcodeproj
├── Config/
│   ├── Base.xcconfig
│   ├── Debug.xcconfig
│   ├── Release.xcconfig
│   └── Secrets.example.xcconfig
├── Click/
│   ├── App/
│   │   ├── ClickApp.swift
│   │   ├── AppEnvironment.swift
│   │   ├── AppRouter.swift
│   │   ├── AppLifecycleCoordinator.swift
│   │   ├── RootGateView.swift
│   │   └── MainTabView.swift
│   ├── Core/
│   │   ├── API/
│   │   │   ├── ClickAPIClient.swift
│   │   │   ├── APIRequest.swift
│   │   │   ├── APIError.swift
│   │   │   ├── AuthenticatedRequestExecutor.swift
│   │   │   └── DTO/
│   │   ├── Auth/
│   │   │   ├── SessionController.swift
│   │   │   ├── SessionVault.swift
│   │   │   ├── LegacyKMPStateMigrator.swift
│   │   │   └── OAuthCoordinator.swift
│   │   ├── Realtime/
│   │   │   ├── RealtimeCoordinator.swift
│   │   │   ├── PresenceService.swift
│   │   │   └── SubscriptionHealth.swift
│   │   ├── Crypto/
│   │   │   ├── LegacyMessageCrypto.swift
│   │   │   ├── MessageCryptoV2.swift
│   │   │   ├── CryptoIdentityStore.swift
│   │   │   ├── EpochKeyStore.swift
│   │   │   ├── AttachmentCrypto.swift
│   │   │   └── CryptoVectors/
│   │   ├── Persistence/
│   │   │   ├── CacheStore.swift
│   │   │   ├── PendingOperationStore.swift
│   │   │   └── SettingsStore.swift
│   │   ├── Media/
│   │   │   ├── MediaVault.swift
│   │   │   ├── ImagePipeline.swift
│   │   │   ├── AudioPlaybackService.swift
│   │   │   └── MediaCompression.swift
│   │   ├── Notifications/
│   │   │   ├── PushRegistrationService.swift
│   │   │   ├── NotificationRouter.swift
│   │   │   └── NotificationPreferencesService.swift
│   │   ├── Permissions/
│   │   │   ├── PermissionCoordinator.swift
│   │   │   └── PermissionState.swift
│   │   ├── Telemetry/
│   │   ├── Performance/
│   │   └── Utilities/
│   ├── Domain/
│   │   ├── Models/
│   │   ├── Repositories/
│   │   └── Services/
│   ├── DesignSystem/
│   │   ├── Colors.swift
│   │   ├── Typography.swift
│   │   ├── Spacing.swift
│   │   ├── Motion.swift
│   │   ├── Haptics.swift
│   │   ├── Components/
│   │   └── GeneratedVisuals/
│   ├── Features/
│   │   ├── Auth/
│   │   ├── Onboarding/
│   │   ├── Home/
│   │   ├── Connect/
│   │   ├── Connections/
│   │   ├── Chat/
│   │   ├── Profile/
│   │   ├── Search/
│   │   ├── Map/
│   │   ├── Beacons/
│   │   ├── Events/
│   │   ├── Hubs/
│   │   ├── Availability/
│   │   ├── CollaborationDrops/
│   │   ├── Settings/
│   │   ├── Safety/
│   │   ├── PriorConnections/
│   │   └── Ticketing/
│   └── Resources/
│       ├── Assets.xcassets
│       └── Localizable.xcstrings
├── ClickClip/
├── NotificationService/
├── SharedCrypto/
├── ClickTests/
├── ClickUITests/
├── Scripts/
└── Docs/
    ├── BACKEND_CONTRACT_MATRIX.md
    ├── PARITY_LEDGER.md
    ├── E2EE_COMPATIBILITY.md
    ├── APPLE_PLATFORM_IDENTITY.md
    ├── PERFORMANCE_GATES.md
    └── HARDWARE_TEST_MATRIX.md
```

This layout is a target, not a reason to create empty abstractions. Directories should be populated only when needed.

---

# 8. Core architectural model

## 8.1 Dependency graph

```text
SwiftUI View
    │
    ▼
@Observable FeatureModel (@MainActor)
    │
    ├── Repository protocol
    │       │
    │       ├── ClickAPIClient / BFF
    │       ├── approved Supabase reads/realtime
    │       └── local cache
    │
    ├── domain service
    │
    └── AppRouter for navigation intent only

Actors / services
    ├── SessionController
    ├── RealtimeCoordinator
    ├── CryptoService
    ├── MediaVault
    ├── ProximityService
    └── PendingOperationStore
```

Views render state and emit user intent. They do not coordinate backend workflows.

## 8.2 `AppEnvironment`

Use a small immutable dependency container similar in spirit to Click Split:

```swift
@Observable
@MainActor
final class AppEnvironment {
    let session: SessionController
    let api: ClickAPIClient
    let realtime: RealtimeCoordinator
    let users: UserRepository
    let connections: ConnectionRepository
    let chats: ChatRepository
    let beacons: BeaconRepository
    let hubs: HubRepository
    let availability: AvailabilityRepository
    let media: MediaRepository
    let notifications: NotificationService
    let permissions: PermissionCoordinator
    let telemetry: TelemetryService
}
```

`AppEnvironment` does not itself become a mutable dumping ground. Mutable domain state belongs to the relevant service/feature model.

## 8.3 Main-actor discipline

- UI models are `@MainActor`.
- JSON decoding, image decoding, crypto, media compression, contact hashing, proximity signal processing, and database/cache serialization must not perform significant work on the main actor.
- Long-lived mutable infrastructure is isolated with actors.
- Do not use `@unchecked Sendable` as a default. Every occurrence needs justification.
- Do not dispatch to `DispatchQueue.main.async` reflexively from async code; use actor isolation.

## 8.4 State ownership

Each piece of user-visible state has one authoritative owner.

Examples:

```text
Authentication state           -> SessionController
Current tab                    -> MainTabView/AppRouter
Per-tab navigation path        -> AppRouter
Chat timeline                  -> ConversationModel
Chat realtime lifecycle        -> ChatRepository/RealtimeCoordinator
Keyboard focus                 -> chat composer view/model
Event engagement               -> EventDetailModel
Media playback                 -> AudioPlaybackService + active bubble binding
Global offline status          -> ConnectivityService
Permission request sequencing  -> PermissionCoordinator
```

Do not maintain duplicate "current chat" state in the inbox, router, notification system, and chat feature. Route with IDs, then resolve feature state at the destination.

---

# 9. Navigation architecture — P0 PARITY / P1 QUALITY

## 9.1 Root gate

The root view must model the product gate explicitly:

```text
launching/migrating
      ↓
restoring session
      ├── unauthenticated -> Auth
      └── authenticated
              ↓
       profile gate pending
              ↓
       ProfileBasics if required
              ↓
       onboarding resolution
              ↓
       active onboarding step
              ↓
       main shell
```

Never briefly render the wrong gate.

There must be no "Home flash" before onboarding, no avatar flash for returning users, and no login flash while a valid offline/local session is being restored.

## 9.2 Main tabs

Current authoritative five roots:

1. **Home** — route `home`
2. **Add Click** — route `add_click`
3. **Clicks** — route `connections`
4. **Map** — route `map`
5. **Me** — compatibility route remains `settings`

`Nearby` is the map-root discovery lip/sheet, **not** the tab title.

Use native `TabView` / current platform tab APIs.

Search is not a sixth tab.

Each root owns its own native navigation stack. Tab switching must not destroy the other tab's navigation/scroll state unless product behavior explicitly resets it. Re-tapping an active tab should return to the tab root if that remains the intended current behavior.

## 9.3 Typed routes

Example:

```swift
enum AppRoute: Hashable {
    case chat(ChatID)
    case userProfile(UserID, connectionID: ConnectionID?)
    case groupProfile(ChatID)
    case event(BeaconID)
    case beacon(BeaconID)
    case hub(HubID)
    case myQR
    case scanQR
    case tapConnect
    case savedEvents
    case settings(SettingsRoute)
}
```

Route values carry identity, not entire mutable model graphs.

## 9.4 Modal ownership

Use one modal owner per navigation scope. Examples:

- profile sheet
- event detail sheet
- connection action sheet
- availability form
- share-to-chat picker
- message action presentation
- beacon creation sheet

Do not let nested features independently present competing full-screen sheets through unrelated global booleans.

## 9.5 Interactive back

Default to Apple's native interactive navigation gesture.

Do not recreate the current Compose/UIKit "persistent chrome morph" machinery. The entire point of the native rebuild is that navigation controller / SwiftUI navigation owns transition timing and chrome together.

If a special chat transition is desired:

- start with native push/pop;
- validate against the desired WhatsApp-like behavior;
- add matched/native transition APIs only if they preserve interactive progress;
- never animate a screenshot proxy while separately swapping real controls;
- header actions and title must remain in the same transition hierarchy as destination content.

## 9.6 Deep-link routing

`AppRouter` queues destination intent until prerequisites are satisfied.

A deep link arriving while logged out:

```text
URL arrives
 -> parse + validate syntactically
 -> store pending typed intent
 -> auth
 -> profile/onboarding gates
 -> resolve authorization/data
 -> navigate
```

A malformed identifier must be ignored with a safe user-facing error if appropriate, never crash.

Required compatibility:

- `click://login...`
- `https://joinclick.co/c/{uuid}`
- `click://c/{uuid}`
- legacy `https://<host>/connect/{uuid}`
- legacy `click://connect/{uuid}`
- `https://joinclick.co/e/{beaconId}` — current AASA routes `/e/*` to the app
- `click://e/{beaconId}`
- `click://hub/{hubId}`
- legacy/current `https://<host>/hub/{hubId}` parser compatibility even though the current `joinclick.co` AASA only advertises `/c/*` and `/e/*`
- push destinations for chats/hubs/reveals/events
- App Clip invocation URLs

Current `joinclick.co` `apple-app-site-association` explicitly advertises `/c/*` and `/e/*` for `W4C3V9Z2N4.compose.project.click.click`. The native rebuild must preserve both. Hub HTTPS links should be parsed when delivered to the app, but must not be described as a guaranteed Universal Link until the AASA also advertises `/hub/*`.

---

# 10. Session and authentication architecture — P0 COMPATIBILITY / P1 HARDENING

The existing app has suffered from JWT/session/realtime drift. The native rewrite must make session correctness boring.

## 10.1 Session state

```swift
enum SessionState {
    case restoring
    case unauthenticated
    case authenticated(SessionSnapshot)
    case refreshing(SessionSnapshot)
    case offlineAuthenticated(SessionSnapshot)
    case terminalError(SessionError)
}
```

A transient refresh/network failure must not immediately masquerade as sign-out.

## 10.2 `SessionController` actor responsibilities

- read migrated/new secure session
- import into Supabase auth adapter
- validate user identity
- single-flight refresh
- persist new access+refresh tokens atomically
- expose access token through an authenticated request executor
- refresh proactively on app foreground/age policy
- handle 401/403 retry path exactly once
- coordinate realtime socket rebind after token refresh
- invalidate feature subscriptions on logout
- clear session-scoped caches on logout
- preserve durable nonsecret product preferences as appropriate
- never expose raw bearer token to UI

## 10.3 Refresh policy

Preserve the mature behavior from current Click:

- boot: validate/refresh rather than trusting wall-clock access-token headroom
- periodic refresh: approximately current 45-minute policy unless backend auth configuration has changed
- foreground recovery: refresh when stale or required
- authenticated request: on 401/403, perform one single-flight forced refresh and retry exactly once
- realtime: after token rotation, explicitly reconnect/rebind if the realtime client does not update an already-open socket
- never start one refresh per failing request
- never enter an infinite 401-refresh loop

## 10.4 Offline authenticated boot

If a locally valid session identity exists but the network is unavailable:

- allow offline shell admission using safe cached app data where current behavior permits;
- mark network-backed sections stale/offline;
- do not fabricate "empty" states;
- retry auth refresh when connectivity returns;
- if server ultimately rejects the refresh token, transition cleanly to login.

## 10.5 Supported auth flows

P0:

- email/password sign in
- email/password sign up
- Google OAuth
- Sign in with Apple if current iOS product exposes it / backend supports it
- OAuth callback `click://login`
- forgot-password handoff to `/forgot-password`
- reset completion on `/reset-password`
- invalid credentials
- cancellation
- network error
- sign out
- persisted session
- OAuth accounts missing profile fields -> ProfileBasics gate

Auth errors must be translated into stable user-facing messages. Never show raw bearer headers, database errors, or opaque server stack text.

---

# 11. Networking contract

## 11.1 `ClickAPIClient`

Build a small typed `URLSession` client.

Responsibilities:

- base URL configuration
- bearer injection
- JSON encode/decode
- request IDs
- timeout policy
- cancellation
- error envelope decode
- one authenticated retry via `SessionController`
- no hidden retry of non-idempotent mutations unless endpoint semantics support idempotency
- multipart/binary upload where required
- server clock/date parsing
- structured logging with secrets redacted

Feature repositories own endpoint-specific DTO mapping.

## 11.2 Error taxonomy

```swift
enum APIError: Error {
    case offline
    case timeout
    case unauthorized
    case forbidden
    case notFound
    case conflict(code: String?)
    case rateLimited(retryAfter: Duration?)
    case validation(code: String?, message: String?)
    case server(status: Int, code: String?, message: String?)
    case decoding
    case cancelled
}
```

A view should never switch directly on HTTP numeric codes.

## 11.3 Backend contract inventory

At minimum, preserve native support for the current mobile-used backend domains:

### User/profile

- secure ping/health where used
- profile fetch
- public profile fetch
- profile patch
- avatar upload
- profile timeline fetch
- journal create/update/delete
- activity recap
- notification preferences
- location/privacy preferences
- interests
- personality traits
- saved events

### Connections

- `GET/POST /api/connections`
- `POST/GET /api/connections/proximity`
- `POST /api/connections/proximity/confirm`
- `POST /api/connections/encounter`
- core GET/POST/DELETE
- archive
- unarchive
- hide
- tags PATCH
- connection tabs
- venue-vibe
- collaboration-session
- event recommendation
- safety report/block/remove paths
- inbox nudges/actions

### QR

- GET QR token
- POST redeem
- preserve 90-second token semantics
- preserve single-use semantics
- preserve proximity failure handling
- then create/restore connection as current protocol requires

### Prior Connections

- `POST /api/contacts/discover`
- `/api/connections/prior/request`
- `/api/connections/prior/respond`

### Chat

- list/read models
- search
- send/write gate
- reactions
- read receipts
- delivery receipts
- attachment upload/signing
- collaboration-session
- group/clique operations
- any v2 device/epoch/key APIs used by current code

### Beacons/events/map

- list/fetch beacon
- create/update/delete
- image upload
- RSVP
- attendee directory
- bookmark
- engagement
- check-in/out
- impression
- share
- my bookmarks
- public event/detail where applicable
- event teaser
- guest list status/paste/match
- nearby hubs
- hub create/join/leave/edit/delete/chat
- event-linked hub access

### Home/insights

- `/api/me/recap`
- widget vibe / home insight data
- event reminders/bookmarks
- nudges/reconnect data where server-backed

### Push

- push token registration
- push-trigger route/function according to current chat architecture

### Ticketing — P2

- Connect onboarding/status
- ticket tiers
- ticket sales status
- checkout
- buyer tickets/credential
- ticket check-in
- order status
- refund

The implementation PR for each domain must update `Docs/BACKEND_CONTRACT_MATRIX.md` with exact method, path, auth requirement, request DTO, response DTO, cache policy, mutation authority, and failure codes.

---

# 12. Domain models

Create stable domain models independent of HTTP/Supabase transport structs.

Expected core types include:

```text
UserID
ConnectionID
ChatID
MessageID
HubID
BeaconID
EncounterID
CollaborationSessionID
TicketID
OrderID

UserProfile
PublicUserProfile
UserInterests
PersonalityProfile
LocationPreferences
NotificationPreferences

Connection
ConnectionStatus
ConnectionSource
ConnectionEncounter
ConnectionContextTags
CoreConnectionState
ConnectionArchiveState
PriorConnectionRequest

Chat
ConversationSummary
ChatParticipant
VerifiedClique
Message
MessageContent
MessageAttachment
MessageReaction
DeliveryState
TypingState
PresenceState
ReplyReference

MapBeacon
BeaconType
BeaconVisibility
EventDetails
EventSchedule
EventEngagement
EventAttendee
EventDirectory
EventBookmark
EventCheckIn
EventGuestListState

CommunityHub
HubMembership
HubAccessState
HubMessage

AvailabilityIntent
AvailabilityOverlap

CollaborationSession
DisposableRollState

ActivityRecap
InboxNudge

TicketTier
TicketOrder
Ticket
TicketCredential
TicketCheckInResult
```

Use small identifier wrappers where they materially prevent mixing IDs, but do not create ceremony for every scalar.

---

# 13. Local persistence and offline architecture

The new app must not reproduce the old pattern where a failed fetch is indistinguishable from legitimate emptiness.

For every feature state, distinguish:

```text
never loaded
loading
loaded(data)
loaded stale(data)
empty (confirmed successful response)
offline cached(data)
error(no cached data)
partial(data, failed subresource)
```

## 13.1 Cache policy

Use a small persistence layer for:

- authenticated user/profile snapshot
- inbox/conversation list
- recent chat timelines
- event bookmarks/engagement
- Home feed snapshot
- connection map summary
- settings/preferences
- active hubs
- pending mutations
- pending proximity handshake
- media metadata, not decrypted secrets unless security policy allows

Do not build a general-purpose local database abstraction until the actual dataset justifies one. A native persistence technology may be chosen after measuring the required queries; isolate it behind repositories.

## 13.2 Pending operations

Operations explicitly supported offline:

- outgoing chat message queue
- proximity handshake capture/sync
- connection save where existing product supports it
- selected low-risk preference changes if conflict semantics are clear

Every queued mutation needs:

- stable client operation ID
- creation time
- user ID
- domain
- payload version
- attempt count
- last error
- idempotency strategy
- cancellation/removal behavior on logout

Never replay a pending operation under a different signed-in user.

---

# 14. Permissions architecture

Use one `PermissionCoordinator` so OS prompts cannot stack.

General sequence:

```text
user initiates capability
 -> read current authorization
 -> if notDetermined: show Click rationale/prime UI
 -> Continue -> request OS permission
 -> denied -> show nonblocking explanation + Settings route
 -> allowed -> perform action
```

Do not request camera/microphone/location/notifications simply because a view mounted.

Required permissions:

| Permission | Used by |
|---|---|
| Location | map, Tri-Factor, hub geofence, event check-in, tether |
| Bluetooth | Tri-Factor / nearby connect |
| Microphone | ultrasonic factor, voice notes |
| Camera | QR scan, avatar capture, chat photo, Click Drops, beacon photo |
| Photos | chat/avatar/beacon media selection and save-to-library where needed |
| Contacts | optional Prior Connections, hashed on-device |
| Calendar | mutual-free-time/calendar features and current reminder integration |
| Notifications | APNs |
| Motion/sensors if required | encounter context only when product uses them |

Ghost mode must not be implemented as "permission revoked." It is a product privacy state layered over platform permissions.

---

# 15. Design and interaction system — P1 QUALITY

The native rewrite is not required to reproduce every Compose implementation detail. It must preserve product identity while allowing the iOS hierarchy to be designed for the platform.

## 15.1 Principles

- Content hierarchy first.
- Native interaction physics.
- One canonical avatar.
- One canonical sheet vocabulary.
- One canonical header/navigation vocabulary.
- One canonical media viewer.
- One canonical event detail.
- One canonical user profile.
- One canonical empty/error/offline pattern.
- Motion communicates continuity; it is not decoration.
- Avoid animation of large blur regions during scroll.
- Never animate independent layers that visually should be one object.

## 15.2 Motion tokens

Create a small `ClickMotion` namespace for repeated non-system transitions only.

Do not globally replace native animations with custom springs.

Categories:

- press/highlight: very short
- selection change: short
- sheet/navigation: system-owned
- content insertion/removal: short, geometry-stable
- connect success/reveal: intentional, haptic synchronized
- loading placeholders: subtle
- no repeated entrance animation when data merely refreshes

Respect Reduce Motion.

## 15.3 Haptics

Central policy:

- selection: filter/segment/toggle where appropriate
- soft impact: lightweight control confirmation
- medium/heavy: meaningful long press/threshold
- success: connection completion/check-in where appropriate
- warning/error: only when interaction merits it

Do not fire haptics because a state recomputed.

## 15.4 Header behavior

Tab-root and pushed-screen headers must be owned by native navigation.

Requirements:

- no title appearing before body transition
- no duplicated title during collapse
- no crossfading between two independent header systems
- no buttons physically jumping when semantic role changes
- safe area/Dynamic Island handled by native bar layout
- large/compact title behavior consistent across roots
- actions stay tappable throughout interactive transition where platform permits

## 15.5 Sheets

Prefer `.sheet`, native presentation detents, confirmation dialogs/alerts, and context menus.

A scrollable sheet must obey native gesture arbitration:

- list scrolls first when mid-content
- downward drag at top may begin sheet dismissal
- no gesture that simultaneously scrolls content and drags parent sheet
- keyboard-safe form sheet
- no black safe-area gap

## 15.6 Loading

Do not make everything appear instantly from nothing merely because cache access is fast. Preserve perceptual continuity, but never add fake fixed delays to routine navigation.

Use:

- cached content immediately when valid
- skeleton only when content structure is genuinely unresolved
- subtle transition from stale/cache to fresh
- stable layout so late data does not move major chrome
- independent section loading for Home rather than gating the entire page

---

# 16. Performance contract — P1 QUALITY

This rewrite fails its purpose if it merely reproduces functionality with native-looking but janky code.

## 16.1 Main-thread budget

On a modern 120 Hz iPhone:

- target frame interval: 8.33 ms
- no routine scroll/navigation work should block main thread for a full 16+ ms frame
- image decode, encryption, JSON-heavy work, compression, database work, and network response processing must be off-main where appropriate

On 60 Hz devices:

- maintain 16.67 ms frame budget for normal interaction

## 16.2 Explicit prohibitions

- no synchronous network request
- no synchronous large image decode in `body`
- no encryption/decryption in `body`
- no O(n) full-thread transformations on every keystroke
- no one `Task` per visible message repeatedly recreated on scroll
- no broad observable object whose unrelated field mutation invalidates the full app
- no full Home reload because one card changed
- no global `withAnimation` around backend refresh state
- no `GeometryReader` in every chat row unless measured and necessary
- no repeated `AnyView` type erasure in hot lists
- no unbounded blur/material layering
- no timer per row
- no polling where Realtime is healthy

## 16.3 Required profiling scenarios

Release configuration, physical device:

1. cold launch authenticated
2. warm launch
3. Home first scroll
4. Home -> Clicks
5. first chat open
6. chat rapid scroll through media + text
7. keyboard open/close
8. send message
9. reaction add/remove
10. swipe reply
11. interactive back from chat
12. profile open
13. profile media open/close
14. Nearby/map pan and bottom sheet
15. event detail open
16. event directory scroll
17. Add Click -> Tap handshake UI
18. camera/QR presentation
19. background -> foreground after 30+ minutes
20. expired access token -> refresh -> realtime resumes

Capture:

- Time Profiler
- SwiftUI update causes where available
- Core Animation hitches
- memory graph
- network task count
- Realtime connection/channel count
- signposts around navigation/data hydration/crypto

No feature is accepted solely because XCTest is green if manual Release-device interaction visibly stutters.

---

# 17. Global app lifecycle

`AppLifecycleCoordinator` handles:

### Launch
1. initialize lightweight logging/config
2. migrate KMP state
3. restore secure session
4. seed safe cached state
5. resolve auth
6. resolve profile/onboarding gate
7. register/rebind realtime only when authenticated
8. register push according to permission/preferences
9. show main shell

### Foreground
1. record foreground event
2. refresh session if policy requires
3. rebind realtime if token/socket stale
4. flush pending operations
5. refresh time-sensitive event/hub/availability state
6. re-read platform permission changes
7. do **not** unconditionally refetch the entire application

### Background
- stop expensive foreground-only sensors
- end ephemeral typing/presence state appropriately
- persist pending work
- retain only allowed background BLE/audio work
- never keep an unnecessary high-frequency task alive

### Logout
- unsubscribe realtime
- stop sensors
- cancel user-scoped tasks
- clear bearer session
- clear session-scoped caches
- clear decrypted media/temp files
- clear in-memory v2 epoch keys
- preserve only deliberately account-independent UI preferences
- route to auth atomically

---

# 18. Product flow master index

The following sections define every current/native flow that must be considered. Every feature implementation must also create corresponding rows in `Docs/PARITY_LEDGER.md`.

1. Launch, migration, auth restoration
2. Login
3. Sign up
4. OAuth / Sign in with Apple / Google
5. Forgot/reset password
6. Profile basics gate
7. Welcome onboarding
8. Interests onboarding
9. Personality onboarding
10. Avatar onboarding
11. Prior Connections onboarding
12. Runtime permission priming
13. Main shell/tab behavior
14. Home
15. Global search
16. Add Click hub
17. My QR
18. QR scanner/connect
19. App Clip connect
20. Tap/Tri-Factor connect
21. Multi-Tap selection/group connection
22. Reconnect encounter
23. connection context tagging
24. event recommendation after connection
25. connection reveal
26. Clicks inbox
27. Remember Me strip / inbox nudges
28. Active/Groups/Archived filtering
29. verified clique create/manage
30. community hub rows
31. direct chat
32. verified group chat
33. event/community hub chat
34. message text send/edit/delete/copy/forward/reply
35. reactions
36. typing/presence
37. delivery/read/unread
38. chat photo/video/image
39. files
40. voice notes
41. media fullscreen/player
42. encrypted media vault
43. connection action/safety
44. vibe check
45. icebreaker
46. 48-hour archive warning/lifecycle
47. collaboration session / Click Drops
48. encounter tether
49. user profile
50. group profile
51. timeline/journal
52. profile Media
53. profile Beacons
54. profile Links
55. memories/sensor context
56. Nearby/map
57. connection pins
58. beacons
59. beacon creation/edit/delete
60. events
61. event engagement (RSVP/bookmark/share/check-in)
62. event directory/mutuals
63. event guest list
64. event reminders
65. community hubs create/join/leave/edit/delete
66. hub geofence
67. availability intents
68. overlap/match alerts
69. Settings profile
70. interests/personality editing
71. notifications
72. ghost mode/privacy/data preferences
73. sensor opt-ins
74. calendar
75. saved events
76. appearance
77. system permissions hub
78. web dashboard handoff
79. push receipt/routing
80. offline/reconnect
81. ticketing (post-parity)
82. latent Clicktivities/achievements audit
83. business/waitlist/venue QR compatibility audit
84. App Clip
85. Notification Service
86. migration/cutover

The remainder of this specification defines these in implementation terms.


---

# 19. Authentication and onboarding flows

## 19.1 Cold launch / returning authenticated user — P0

### Entry
App process starts from:
- icon
- notification tap
- universal link
- custom URL
- App Store/TestFlight update
- background restoration

### Required sequence

```text
LaunchPlaceholder
  -> LegacyKMPStateMigrator
  -> SessionController.restore()
  -> load cached identity/snapshot
  -> validate/refresh session if network permits
  -> fetch/resolve profile gate
  -> resolve onboarding state
  -> MainTabView or appropriate gate
  -> execute queued deep-link intent
```

### Acceptance

- no login flash when a restorable session exists;
- no Home flash before profile/onboarding resolution;
- no Avatar flash for a user who has a remote avatar;
- a network outage with a known local session can enter the supported offline shell;
- an actually invalid refresh token eventually routes to auth once;
- a pending notification/deep link survives the gate sequence;
- startup work does not block the main thread with crypto/database/image processing.

---

## 19.2 Email/password login — P0

### UI
Native form:
- email
- password
- show/hide password as appropriate
- Sign In CTA
- Google/Apple options if current product exposes them
- sign-up navigation
- forgot password

### States
- idle
- validating
- authenticating
- profile resolving
- success
- invalid credentials
- network failure
- rate limit
- account state error
- cancelled request

### Behavior
On success:
1. persist session securely;
2. load user identity;
3. run profile basics gate resolution;
4. resolve onboarding;
5. initialize realtime after auth;
6. register/flush pending push token if applicable;
7. route to pending destination or Home.

A rapid double tap cannot initiate two sign-ins.

---

## 19.3 Sign up — P0

### Inputs
Use current product fields and backend semantics:
- email
- password
- profile identity fields where currently collected
- birthday rules
- auth metadata only for provider-required/fallback data, not as the durable product profile source

### Birthday
Preserve current product safety rule:
- valid date
- age >= 13
- normalized input
- native date picker
- typed input remains possible if current UX retains it

### Success
New account proceeds through the actual onboarding gate sequence, not directly to Home.

---

## 19.4 Google OAuth — P0

- use current configured OAuth client;
- return through `click://login`;
- handle callback once;
- tolerate user cancellation;
- avoid duplicate handling from both scene URL and auth session callback;
- reconcile `public.users` after auth;
- if first name/birthday missing, enter ProfileBasics gate.

---

## 19.5 Sign in with Apple — P0 if currently exposed

Use `AuthenticationServices`.

Requirements:
- nonce/state protection according to Supabase/provider requirements;
- first authorization may supply name, later ones may not;
- durable profile remains in Click tables;
- cancellation returns to idle auth state without an error alert;
- revoked credential eventually results in normal auth recovery.

---

## 19.6 Forgot/reset password — P0

Current mobile behavior delegates the reset web UX.

- Forgot Password opens the correct `/forgot-password` URL.
- Do not send the user directly to `/reset-password`.
- Reset email opens the web reset flow.
- After password change, user can return and sign in normally.
- If a future native reset flow is introduced, it must preserve Supabase's recovery token semantics and be separately specified.

---

## 19.7 Profile Basics gate — P0

Blocking gate after auth for accounts missing required profile fields.

Required:
- first name
- last name/current supported name fields
- birthday when required
- no bypass/back to main shell
- server save
- cached user refresh
- validation:
  - required name
  - valid date
  - 13+ age
- saving/error states

The gate must be based on server profile truth, not simply "first launch on this device."

---

## 19.8 Active onboarding order — P0

Current authoritative order:

```text
Loading
 -> Welcome
 -> Interests
 -> Personality
 -> Avatar
 -> Prior Connections
 -> Complete
```

Full gate sequence:

```text
Authenticated
 -> profile gate pending?
 -> ProfileBasics if active
 -> onboarding remote resolution
 -> Welcome if unseen
 -> Interests if incomplete
 -> Personality if required for new account
 -> Avatar if neither remote avatar nor local set/skip
 -> Prior Connections
 -> completion handoff
 -> Home
```

Legacy `PermissionsOnboardingScreen` and `LocationOnboardingScreen` are **not** active full-screen onboarding steps and must not be resurrected. Runtime permissions use contextual prime flows.

### Back behavior
- Welcome: no back
- later onboarding screens: native back according to onboarding state machine
- returning to earlier screens must not erase server-saved data
- persisted/remote completion must prevent incorrect screen flashes

---

## 19.9 Welcome — P0

Preserve product intent:
- Click is in-person first;
- explain encrypted/private messaging accurately;
- avoid claims broader than the actual crypto threat model;
- CTA advances;
- no permission prompt on screen appearance.

Exact visual implementation may be redesigned natively while retaining the content hierarchy.

---

## 19.10 Interests — P0

- at least 5 interests required;
- taxonomy comes from the existing product/source;
- selected state clear;
- save server-side;
- save failure remains on screen with recoverable feedback;
- no "empty succeeded" assumption after failed fetch;
- settings later edits same underlying data.

Use native `ScrollView`/lazy layout and accessible selection controls.

---

## 19.11 Personality — P0 for new-user flow

- exactly 5 traits;
- shown for new signups when incomplete;
- legacy-complete accounts do not get unexpectedly gated;
- same durable profile domain used by Settings;
- current Settings helper: `Pick exactly 5 traits.`

Do not derive completion merely from local defaults if server traits exist.

---

## 19.12 Avatar — P0

- existing remote avatar prevents this screen from flashing;
- unknown avatar state stays in loading/resolution, not "no avatar";
- choose from Photos;
- camera capture;
- local preview;
- upload;
- skip;
- recoverable permission error;
- recoverable network error;
- refresh profile after successful upload.

Use one canonical image compression pipeline and avatar uploader across onboarding and Settings.

---

## 19.13 Prior Connections — P0 if active onboarding remains product intent

This is a newer flow and must not be omitted because older July UI indexes do not emphasize it.

### Purpose
Optionally find people already known by the user without representing those edges as verified in-person Click encounters.

### Privacy contract
- read contacts only after explicit user action/permission;
- normalize phone numbers/emails on-device;
- SHA-256 normalized values on-device;
- upload hashes only;
- never upload plaintext address book fields;
- communicate this accurately in permission copy.

### Backend
- `POST /api/contacts/discover`
- `POST /api/connections/prior/request`
- `POST /api/connections/prior/respond`

### Semantics
- `source=prior`
- never mint `connection_encounters` from self-reported prior relationship;
- never count as verified proximity handshake metrics;
- skippable.

### States
- explanation
- contacts permission unknown
- permission denied
- hashing
- discovering
- matches
- no matches
- request pending
- request accepted/declined
- backend error
- skip

Contact hashing runs off-main.

---

# 20. Main shell and Home

## 20.1 Main tab shell — P0/P1

Current native tab bar roots:

```text
Home
Add Click
Clicks
Map
Me
```

Compatibility route identities remain:

```text
home
add_click
connections
map
settings     # user-facing title is Me
```

`Nearby` is the compact discovery lip/native sheet inside the Map root; it is not a sixth tab and not the Map tab's current label.

Requirements:
- native tab interaction;
- stable safe-area behavior;
- no custom Compose/UIKit bridge;
- preserve root state across tab switching;
- reselect active tab -> root according to current behavior;
- tab bar hides only on full-screen/pushed flows where native hierarchy dictates;
- **Me uses the signed-in user's profile photo as the tab image when available and a person-circle fallback otherwise;**
- an avatar change retargets only the existing Me tab item—do not recreate the whole tab bar and rematerialize native chrome;
- accessibility label remains `Me` even though its internal compatibility route is `settings`.

---

## 20.2 Home — P0

Home is a composed dashboard, not an infinite feed.

### Current hierarchy/capabilities

The September refinement plan supersedes the older dashboard-like ordering. Home should read as a **linear social activity feed** in roughly this hierarchy:

1. expanded greeting + search;
2. current availability/intent;
3. one most-relevant social prompt — featured event, reconnect, Poll-Pair/archive warning as applicable;
4. recap/recent activity;
5. saved/upcoming events;
6. nearby discovery based on real data/counts;
7. lower-priority insights/statistics.

Preserve the underlying capabilities when data exists:
- time-of-day greeting + first name in expanded state;
- compact native title becomes `Home`;
- unified search entry;
- "I'm down for…" availability intentions;
- featured event/reminder;
- reconnect reminders;
- Poll-Pair/archive warning behavior where applicable;
- recap and recent connections/activity;
- saved/upcoming events;
- event reminders;
- nearby Explore/discovery categories based on real counts, never fake fixed categories;
- connection insights/statistics as secondary content.

Do not port the retired photo-pile presentation (§20.2.1). Avoid equal-weight bordered dashboard cards; use hierarchy/spacing and one dominant CTA per section.

### Loading architecture
Every independent module must be independently loadable.

Bad:

```text
await profile
await events
await stats
await nearby
await recents
render whole Home
```

Required:

```text
render stable Home scaffold
seed cached modules
refresh modules concurrently where safe
update each stable keyed section independently
```

A slow recap must not make the rest of Home wait or suddenly shift after the user has begun scrolling.

### Refresh
- explicit pull-to-refresh or native refresh affordance;
- coalesce duplicate network work;
- do not replay page entrance animation on refresh;
- stale cached section is distinguishable from confirmed empty when materially relevant.

### Navigation
- featured/saved event -> canonical Event Detail;
- "View on Map" -> Nearby tab + focus beacon;
- reconnect Message -> canonical chat;
- recent connection -> canonical chat/profile according to tap target;
- availability -> canonical availability sheet;
- search -> global search.

### Performance
No Home card should independently fetch the same user/avatar/event resource. Repository/cache deduplicates.

## 20.2.1 Home layout — LINEAR ONLY / DO NOT PORT PHOTO PILE

The current repository contains stale July documentation and dead/retained photo-pile implementation files, but the **September 6 stabilization record and current runtime code supersede them**.

Authoritative current state:

- approved product intent is a **linear-only Home feed**;
- `HomeLayoutMode.fromStored(...)` currently returns `LINEAR` unconditionally;
- the photo-pile/layout toggle is explicitly documented as **removed and not a release requirement**;
- no production call site for `homePhotoPileItems(...)` or `setHomeLayoutMode(...)` was found in the verification audit;
- remaining pile components/tests/storage keys are compatibility/dead-code residue, not a user flow to port.

Therefore `click-ios` must:

- implement the linear Home feed only;
- **not** add a Home pile/list toggle;
- **not** add Settings → `Photo pile home`;
- ignore legacy `home_layout_mode` for product behavior (it may be read only to complete a safe migration/cleanup, but resolves to linear);
- preserve the independently reachable Home modules and stable item identities;
- retain deterministic generated visuals where those visuals are still used by event/beacon cards, without retaining pile physics.

This disposition overrides stale July `docs/ui-ux/mobile/05-home.md` / `14-settings-privacy.md` text and leftover pile source files.

---

## 20.3 Home activity recap / insights — P0 if currently surfaced

Backend examples:
- `/api/me/recap?window=day|week`
- widget-vibe/insight route

States:
- cached result
- fresh result
- empty ("make your first Click" style current copy)
- partial failure
- auth warming
- hidden when genuinely unavailable

A backend failure must not render a fake zero-stat recap.

---

## 20.4 Reconnect reminders — P0

- show eligible person/context;
- Message -> chat;
- Dismiss -> server/local action according to current route;
- preserve inbox nudge consistency;
- do not duplicate same recommendation across Home and inbox in a visually disruptive way unless product deliberately permits it.

---

## 20.5 Event reminders — P0

Current product uses day-of / one-hour-before style reminders.

Required:
- one stable event identity;
- dismiss;
- canonical Event Detail;
- map focus;
- no duplicate featured card for same event if product logic suppresses duplication;
- reconcile with push notification route.

---

# 21. Global Search — P0

## 21.1 Entry
Opened from root header/search control as a native sheet/full-screen search surface according to final design.

## 21.2 Search domains
Current filters include concepts such as:
- Active
- Archived
- Cliques
- Nearby
- Beacons
- Intents
- people/connections
- messages/conversations
- hubs/events as supported

Do not hardcode result categories from an old mock. Use current backend/search contract.

## 21.3 Search behavior
- debounce only network-bound search;
- immediate local filtering where appropriate;
- cancel stale queries;
- preserve query while viewing/dismissing child result as product dictates;
- clear distinction:
  - initial
  - searching
  - results
  - no results
  - error
- backend error must never display simply `No results`.

## 21.4 Routing
A result routes to the canonical destination:
- person -> profile or conversation
- chat/message -> chat with optional message anchor
- beacon/event -> event/beacon detail or map focus
- hub -> hub detail/chat
- availability -> relevant profile/intent surface

Message search must be compatible with encrypted-message search limitations. Do not pretend server can search plaintext v2 message bodies if it cannot.

---

# 22. Add Click / connection initiation

## 22.1 Add Click root — P0

Entry choices:
- Tap to Connect
- Scan QR
- My QR
- Community hub creation entry only if still intentionally surfaced here

This screen should be sparse and interaction-led.

---

## 22.2 My QR — P0

Current iOS App Store listing ID used by the App Clip/full-app CTA is:

```text
6757996346
https://apps.apple.com/app/id6757996346
```

Preserve this existing listing identity unless App Store Connect intentionally changes it.

### Backend
`GET /api/qr`

Current server behavior:
- auth required;
- 32-byte token;
- 90-second TTL;
- optional initiator lat/lon;
- universal-link payload;
- legacy deep-link fields.

### Client
- show current QR;
- visibly refresh before/at expiry;
- never keep an expired token onscreen indefinitely;
- share link with native share sheet;
- keep screen awake if product wants reliable scan behavior;
- refresh on foreground if expired;
- no timer-per-render bug.

### QR payload compatibility
Support current server format rather than inventing a Swift-only format.

Current compatibility forms include:

```text
https://<host>/c/{uuid}
click://c/{uuid}
https://<host>/connect/{uuid}      # legacy
click://connect/{uuid}            # legacy
```

Token QR JSON fields currently include:
- `token`
- `userId`
- `exp`
- optional `name`
- optional `issuedAt`
- optional `venue_id`

Token-bearing connection links may use query aliases:
- `token`
- `qr_token`
- `qt`
- expiry: `exp` / `expires_at`
- issued-at: `iat` / `issued_at`
- `venue_id`

Parsing is compatibility code; new generation should use the canonical current server format.

---

## 22.3 QR Scanner — P0

Use native camera APIs.

State:
- permission unknown/denied/allowed
- initializing camera
- scanning
- code recognized
- validating/redeeming
- context sheet
- error
- dismiss

Rules:
- process one candidate at a time;
- throttle duplicate camera detections;
- accept current universal/legacy QR forms;
- malformed non-Click QR -> safe feedback;
- expired/already-used/proximity-failed -> current product error treatment;
- dismiss scanner cleanly back to Add Click.

### Redeem
`POST /api/qr` with scanner location/sensor payload as required.

On existing connection:
- record encounter;
- open collaboration session according to backend semantics.

On new pair:
- complete the connection creation/restore flow as current protocol requires.

---

## 22.4 App Clip connection — P0 COMPATIBILITY

Invocation:
- parse `/c/{userId}` + token/current query;
- fetch minimal public profile;
- explain connection action;
- request only capabilities allowed/necessary for App Clip;
- redeem through the same backend;
- handle authentication/ephemeral identity exactly as current supported flow requires;
- encourage full app install only after useful action, not before.

The full app opening after App Clip should not create a duplicate connection.

---

# 23. Tri-Factor proximity handshake — P0

This is a core Click differentiator. Do not simplify it to BLE-only merely because native iOS makes BLE straightforward.

Current conceptual factors:
- BLE presence/session framing
- ~18.5 kHz ultrasonic token evidence
- progressive high-accuracy GPS

Backend remains the final verifier.

## 23.1 Native architecture

```text
TapConnectFeatureModel
     │
     ▼
ProximityCoordinator (actor)
     ├── BLEProximityService
     ├── UltrasonicService
     ├── LocationEvidenceService
     ├── EncounterContextService
     └── ConnectionRepository
              │
              ▼
       click-web / Edge validation
```

Each sensor reports evidence to the coordinator. No SwiftUI view owns a BLE central or audio engine.

## 23.2 State machine

At minimum:

```text
idle
preparingPermissions
fetchingLocation
startingSensors
listening
submitting
pendingPeer
awaitingSelection(peers)
confirmingSelection
contextTagging
success
offlineQueued
recoverableError
fatalError
cancelled
```

Transitions must be explicit and unit tested.

## 23.3 Timing
Current regression expectation uses roughly a 5-second listen/handshake window. Preserve server/client protocol behavior unless proximity code currently specifies a newer value.

Do not use visual animation duration as protocol timing.

## 23.4 Backend semantics

`POST /api/connections/proximity`:
- may return immediate result or `202 Accepted` pending ID;
- current validation includes:
  - normalized last-four token evidence
  - GPS <= 15m when both coordinates are present
  - mutual-hear/heard-token intersection evidence
  - graph/BFS logic for 3+ clique
  - bounded candidate search

Client may need:
- GET pending handshake
- background/foreground recovery
- confirm selected multi-peer members

Do not reproduce GPS threshold, token matching, graph validation, or clique correctness rules as authoritative Swift logic. Client can provide UX-level preliminary feedback, but server decides.

## 23.5 iOS BLE
Implement correct CoreBluetooth lifecycle:
- central/peripheral roles according to current protocol;
- deterministic advertisement payload compatibility;
- state restoration only if current product requires it;
- Bluetooth-off state;
- permission denied state;
- app foreground/background state;
- dedupe devices/session tokens;
- no unbounded scan;
- stop radio work immediately on cancellation/completion.

## 23.6 Ultrasonic
Implement with AVFoundation:
- exact waveform/token protocol compatible with current clients;
- sample/FFT processing off-main;
- robust audio-session category transitions;
- relinquish audio session after handshake;
- coordinate with voice-note playback/recording;
- permission denial fallback UX according to product/backend acceptance;
- never leave microphone active after flow.

## 23.7 Location
- request high accuracy only during meaningful handshake/geofence action;
- capture horizontal accuracy/timestamp;
- timeout gracefully;
- never block all UI indefinitely waiting for impossible precision;
- pass evidence expected by server.

## 23.8 Cancellation/background
If user exits:
- cancel active scan/audio/location tasks;
- preserve already-submitted pending handshake ID if backend may still match;
- recover on return when appropriate.

If app backgrounds:
- follow allowed background modes;
- do not assume process remains alive;
- persist only the minimal recoverable pending handshake state.

---

# 24. Multi-Tap — P0

When 3+ candidates are matched:

1. server returns/represents `awaiting_selection`;
2. show **People** selection before context tags;
3. host selects at least one intended peer according to current semantics;
4. cap selection at <= 12;
5. confirm through server;
6. server creates/registers correct fully connected group/clique state;
7. client resolves group chat;
8. cache/receive crypto epoch/master-key state;
9. reveal/open expected destination.

Important:
- do not expose old "Connect with everyone" behavior if current product requires explicit people selection;
- abandoning selection must not create a half-group;
- participants must receive group/inbox update in realtime;
- group avatar generation uses the same canonical logic everywhere;
- no duplicate 1:1 rows created as an accidental side effect.

---

# 25. Reconnect encounters — P0

A repeat physical connection with an existing peer should create/merge encounter context rather than duplicate the relationship.

Required:
- stable existing `ConnectionID`;
- new encounter row when backend semantics allow;
- backend debounce semantics respected (current web docs mention 50m + same 12-hour UTC block -> Extended Hangout);
- no duplicate Active chat row;
- no duplicate personal map connection pin;
- collaboration session may open;
- context tagging available;
- profile timeline updates without forcing an app cache reset;
- event context attached per eligible reporting user.

---

# 26. Connection context tagging — P0

Modes include new connection / QR / reconnect as current product defines.

Features:
- suggested tags
- all tags
- multi-select
- skip/cancel
- save
- context-specific copy
- event recommendation when available
- sensor context collection when user opted in

For Multi-Tap, People selection is above tags.

Saving tags updates the authoritative connection/encounter target and refreshes the relevant timeline/cache.

---

# 27. Event recommendation after connection — P0 if currently surfaced

Endpoint/current repository support exists for a shared upcoming event recommendation after a connection.

Flow:
- recommendation card in post-connect context;
- RSVP
- Dismiss
- Event Detail
- failure does not block completing the connection.

---

# 28. Connection reveal — P0/P1

After successful connect:
- intentional success animation;
- heavy -> success haptic sequence if retained;
- show peer/group identity;
- no excessive particle/blur cost;
- dismiss -> Clicks or relevant final destination;
- must not race with backend creation such that reveal appears before chat/connection is resolvable.

---

# 29. Clicks inbox — P0

## 29.1 Segments

Current primary modes:
- Active
- Groups
- Archived

Preserve:
- filtering
- sort/filter menu
- core connection priority
- unread counts
- preview
- online indicator
- group/hub rows
- empty states
- current search-within-list behavior if still present

## 29.2 Conversation list architecture

`ConversationListModel` loads:
- cached list immediately;
- server list;
- realtime message/inbox changes;
- presence separately.

A message insert should update only affected row ordering/preview/unread, not refetch/rebuild every conversation.

Stable IDs are mandatory.

## 29.3 Realtime new conversation
New DM/group created on another device or by another group participant must appear without pull-to-refresh.

The previous app had a known gap around subscribing only to message inserts rather than new chat membership. The native client must explicitly subscribe to or otherwise receive the relevant conversation/membership change signal.

## 29.4 Row interactions
- row tap -> chat
- avatar -> canonical profile
- long press/context menu -> connection/group actions
- unread badge
- presence
- last message
- timestamp
- delivery preview as current design requires

Use native context menus where suitable.

---

## 29.5 Remember Me strip — P0 if active

Current inbox includes `RememberMeStrip` for core 1:1 connections under eligible conditions.

Requirements:
- no duplicate presence/avatar implementation;
- tap -> chat/profile according to current UX;
- section hidden when irrelevant/search active;
- stable horizontal scroll;
- cache avatars.

---

## 29.6 Inbox nudges — P0 if active

Current server-supported nudge actions include:
- dismiss
- snooze
- acted

Nudge examples include reconnect/shared-event prompts.

Requirements:
- no nudge reappears immediately after a successful server action because stale cache overwrote optimistic state;
- action failure restores/reconciles;
- tapping the action navigates to canonical destination.

---

## 29.7 Connection actions — P0

For 1:1:
- Nudge — current behavior is a special `👋` message sent through the connection's ordinary chat pipeline; do not invent a separate native nudge transport/API;
- Archive
- Unarchive
- Add to Core
- Remove from Core
- Mark Unread
- Remove connection
- Report
- Block

For groups:
- Mark Unread
- rename where allowed
- leave
- delete if allowed
- member management through group profile

Destructive actions:
- native confirmation
- explicit pending state
- backend success before permanent disappearance unless optimistic behavior has a robust rollback
- no duplicate action route implementations between inbox and chat header

---

# 30. Verified clique/group management — P0

### Create manually
- Active tab/group create entry;
- eligible member picker;
- only permitted graph members;
- create verified clique;
- initialize current E2EE protocol;
- open group chat;
- peers receive group update.

### Manage
- group profile;
- member list;
- generated/custom avatar;
- add eligible member;
- remove member;
- rename;
- leave;
- owner/admin delete if current product supports it.

Any membership change in an upgraded encrypted group must trigger the appropriate E2EE v2 epoch rotation protocol. UI success is not complete until encryption state can continue correctly.

---

# 31. Chat architecture — P0 / P1

Chat is a top-tier performance and product-quality surface. It must be implemented as a first-class native feature, not a port of the old `ChatView.kt`.

## 31.1 One conversation feature, parameterized by conversation kind

```swift
enum ConversationKind {
    case direct(ConnectionID)
    case verifiedGroup(ChatID)
    case communityHub(HubID)
}
```

Not every behavior is shared—hub encryption/access differs—but common UI should not be copied into three unrelated screens.

## 31.2 Conversation state

```swift
@Observable
@MainActor
final class ConversationModel {
    let identity: ConversationIdentity

    var phase: LoadPhase
    var items: [MessageItem]
    var typingUsers: [UserID]
    var participants: [UserProfile]
    var replyTarget: MessageID?
    var editTarget: MessageID?
    var stagedAttachments: [StagedAttachment]
    var composerText: String
    var pagination: PaginationState
    var realtimeHealth: SubscriptionHealth
    var sendState: SendState
}
```

Feature model should not contain actual AVPlayers per row or raw websocket implementation.

## 31.3 Timeline

Requirements:
- initial page;
- older pagination;
- stable scroll anchor;
- incoming messages near bottom -> maintain latest behavior;
- user scrolled up -> do not yank them to bottom;
- initial load should not visibly bounce from wrong offset;
- inserted reaction/status must not change unrelated message geometry;
- date separators;
- reply references;
- encrypted/decrypting state;
- failed/deleted messages;
- collaboration/event cards as applicable.

## 31.4 Scroll implementation
Start with native SwiftUI scrolling APIs available for target SDK. If precise chat anchoring cannot meet acceptance criteria, isolate a UIKit `UICollectionView` implementation behind one conversation timeline view rather than adding gesture hacks around SwiftUI.

Acceptance:
- rapid scroll is consistently smooth;
- scroll indicator is native and controllable;
- no artificial "jump" caused by state replacement;
- history prepend preserves visual anchor;
- keyboard appearance does not cause a second delayed scroll jump;
- media dimensions are known/reserved before image loads where metadata permits.

---

# 32. Chat composer — P0/P1

Components:
- multiline native text input;
- attachment action;
- send;
- voice recording entry;
- reply quote;
- edit state;
- staged photo/file chips;
- character limit (current code uses 1000 unless backend/current product changed).

Keyboard:
- rely on native safe-area/keyboard layout;
- no manually delayed 200ms compensation;
- no independent animation curve fighting system keyboard;
- composer follows keyboard interactively;
- dismissal works by native scroll/gesture expectations.

Send:
- optimistic local message with stable client ID;
- encrypt off-main;
- persist/send;
- update status without replacing list identity;
- queue offline;
- retry failed message deliberately.

---

# 33. Message operations — P0

## 33.1 Text
- send
- copy
- reply
- edit own message
- delete own message
- forward
- mark/read semantics

## 33.2 Reply gesture
- received: expected directional swipe
- sent: expected directional swipe
- one threshold haptic
- gesture cannot steal vertical scroll
- settles smoothly
- reply target binds to stable message ID
- cancel collapses quote area without layout jump

Use simultaneous/exclusive gesture relationships carefully. Do not attach a broad horizontal drag to the entire conversation screen if it conflicts with interactive back.

## 33.3 Long press
Native context menu or native-feeling action sheet:
- reply
- reactions
- copy
- edit if eligible
- delete if eligible
- save/share media
- forward

Text selection must not unexpectedly compete with the action behavior.

## 33.4 Reactions
- quick emoji strip/current set
- add
- toggle/remove
- realtime update
- preserve bubble geometry
- reaction count/users if current UI exposes them

## 33.5 Edit
- only eligible own text messages;
- enter edit mode;
- composer shows edit state;
- save;
- cancel;
- server update;
- v2 encryption compatibility for replacement content;
- failure does not lose original displayed message.

## 33.6 Delete
- confirm;
- backend delete semantics;
- remove/tombstone consistently on peers;
- two-step confirmation if current safety UX requires it.

## 33.7 Forward
- target picker;
- decrypt source locally;
- construct a new message for destination;
- encrypt with destination context;
- do not copy ciphertext blob from source chat into another chat;
- media forwarding uses secure download/re-encrypt/upload semantics.

---

# 34. Delivery, read, unread, typing, presence — P0

## 34.1 Delivery
Represent:
- local pending
- sending
- sent/server accepted
- delivered
- read
- failed

Never infer "read" merely because recipient is online.

## 34.2 Read
When thread visible and appropriate:
- mark server-side;
- batch/coalesce;
- update inbox unread state;
- dismiss matching notification.

Hub chat must not display a fake direct-message blue read receipt.

## 34.3 Mark unread
Manual action updates local/server unread state consistently for direct and group.

## 34.4 Typing
Ephemeral:
- send start/refresh;
- timeout/clear;
- leave channel clear;
- no durable database write;
- throttle network.

## 34.5 Presence
Shared/current presence architecture:
- healthy
- reconnecting
- unavailable
- idle

UI should not show "Offline" as an asserted fact when presence subscription is simply disconnected. Model uncertainty appropriately.

---

# 35. Chat realtime — P0 HARDENING

The existing app had failures where subscription setup order, auth token rotation, or overlapping detach/subscribe caused silent stale chat.

Native requirements:

1. listener registration happens before channel join according to Supabase client semantics;
2. one active subscription set per conversation;
3. cancellation of previous subscription is awaited before a new same-topic subscription;
4. token refresh triggers re-auth/rebind;
5. subscription health is observable;
6. retry with bounded backoff;
7. degraded fallback polling may exist only as a safety net, never as the primary normal path;
8. errors are logged structurally and can surface a subtle reconnect state;
9. app foreground does not create duplicate channels;
10. leaving a conversation tears down conversation-specific ephemeral subscriptions;
11. inbox-level realtime remains independently healthy.

---

# 36. Chat E2EE compatibility — P0 RELEASE BLOCKER

Do not implement chat crypto from memory. Port from current audited Click protocol with golden vectors.

There are **two protocol generations** to support.

## 36.1 Legacy v1 read compatibility

Legacy direct:
```text
master = SHA-256(
  "click-platforms-e2ee-v1-2024"
  || sorted(userId1,userId2)
  || connectionId
)
encKey = SHA-256(master || 0x01)
macKey = SHA-256(master || 0x02)

payload = IV[16] || HMAC[32] || AES-CBC ciphertext
wire = "e2e:" + Base64(payload)
```

Legacy clique:
- prefix `e2e_grp:`
- random 32-byte group master
- old wrapping semantics retained for reads.

Legacy hub:
- public-ID-derived key is **legacy compatibility only**, not a security boundary.

## 36.2 E2EE v2 writes/current protocol

Current upgraded direct/clique/event-hub:
- per-device X25519 identity;
- private identity in Keychain with ThisDeviceOnly/WhenUnlocked;
- random 256-bit epoch key;
- wrap to active devices using ephemeral X25519 + HKDF-SHA256 + AES-256-GCM;
- server holds public identities, epoch metadata, opaque envelopes;
- authenticated envelope includes chat/hub ID, client message ID, sender device, epoch, crypto version, nonce, ciphertext digest;
- replay/nonce reuse protections;
- membership/device changes rotate epoch;
- upgraded chats reject legacy writes;
- historical direct-chat key transfer follows approved device-transfer flow;
- hub new devices are scoped according to current epoch policy.

## 36.3 Required implementation artifacts
Before shipping:
- `Docs/E2EE_COMPATIBILITY.md`
- exact wire structs
- exact canonical serialization
- current key API route matrix
- current device identity schema
- golden test vectors imported from KMP/current server tests
- cross-client fixture suite

## 36.4 Golden compatibility tests
Swift must prove:
- decrypt KMP v1 fixture;
- encrypt v1 fixture if any remaining compatibility write requires it;
- decrypt KMP v2 direct fixture;
- Swift v2 direct ciphertext decrypts in KMP fixture harness;
- group v2 parity;
- hub v2 parity;
- membership rotation;
- device rotation;
- replay rejection;
- nonce-reuse rejection;
- corrupted AAD rejection;
- wrong chat ID rejection;
- wrong epoch rejection.

No production cutover before these pass.

---

# 37. Chat attachments and media — P0

## 37.1 Media categories
- image/photo
- file
- audio/voice note
- event/beacon card metadata
- Click Drop/disposable image

Video should be implemented only if current product/backend actively supports it; do not assume from generic media pickers.

## 37.2 Upload pipeline

```text
pick/capture
 -> validate size/type
 -> compress/prepare off-main
 -> generate file encryption material / v2 attachment context
 -> encrypt
 -> upload opaque bytes
 -> insert/send encrypted message metadata
 -> render optimistic/local media
```

No plaintext cloud upload for private chat attachment.

## 37.3 Download pipeline

```text
message metadata
 -> authorize/sign URL
 -> download ciphertext
 -> verify/decrypt
 -> store in temporary/media vault
 -> decode/play/display
```

No repeated download/decrypt every time a cell re-enters viewport.

## 37.4 Image
- reserved aspect ratio/size avoids scroll jump;
- async thumbnails;
- tap -> one canonical fullscreen media viewer;
- share/save operate on decrypted local bytes;
- permission for save is contextual;
- transition back to chat/profile does not flash prior navigation chrome.

## 37.5 File
Current bug class: file attachment must not look like inert plaintext.

Native file bubble:
- icon/type;
- filename;
- size if known;
- download/progress/error;
- tap opens Quick Look or appropriate system preview;
- native share;
- decrypted temporary file lifecycle;
- same rendering semantics in chat/profile Media where appropriate.

## 37.6 Audio / voice notes
Current bug class must be explicitly prevented.

Recording:
- request microphone contextually;
- one recording session;
- waveform/time if desired;
- cancel;
- preview;
- send;
- upload failure stays scoped to the originating conversation only.

Playback:
- one shared `AudioPlaybackService`;
- play/pause;
- seek slider;
- elapsed/remaining;
- dragging seek must win over swipe-to-reply/page switching gestures;
- switching conversations must not display failed audio state in every chat;
- audio bubble must not be wrapped inside an unnecessary generic text bubble;
- interruption/headphone route handling;
- background playback only if product intentionally supports it.

Profile media audio uses the same player behavior.

---

# 38. Fullscreen media — P0/P1

One canonical `MediaViewer` used from:
- chat
- profile Media
- group profile
- event/beacon content if appropriate

Capabilities:
- image zoom/pan
- audio/file controls as applicable
- native dismiss
- share
- save/download where policy allows
- current index for multi-item gallery
- no duplicated navigation controls
- interactive dismissal
- return destination preserves scroll state

The media viewer must not leak toolbar state into the underlying app after dismissal.

---

# 39. Push notification preview crypto — P0

`NotificationService` must support the actual current encryption protocol.

The current old extension has legacy direct-message preview derivation and fallback. E2EE v2 may require richer payload/key access constraints.

Rule:
- if extension can safely decrypt with available key material, display appropriate preview;
- otherwise use privacy-safe fallback such as "Open Click to view it";
- never weaken v2 key storage merely to improve push preview;
- never put plaintext message content on the server solely for notification convenience.

---

# 40. Chat header / profile navigation — P0/P1

Direct:
- avatar
- peer display name
- presence state
- avatar/profile tap -> canonical user profile
- overflow -> canonical connection actions

Group:
- group avatar
- group name
- member summary
- avatar/header -> canonical group profile
- overflow -> group actions

No call buttons.

Header uses native navigation chrome and participates in interactive back with the whole destination.

---

# 41. Vibe Check — P0 if currently active

Current semantics include a roughly 30-minute mutual opt-in window.

Preserve:
- new-connection eligibility
- Keep / Pass
- mutual server state
- expiry
- no stale banner after outcome
- explicit backend rule owner

Do not rebuild matching/expiry logic as local Swift timers that determine durable truth.

---

# 42. Icebreakers — P0 if currently active

- visible when current message-count/window criteria allow (current docs mention <5 messages);
- server/current cooldown;
- tapping sends a real chat message through the ordinary encrypted send pipeline;
- panel disappears/updates without jumping the timeline.

---

# 43. 48-hour gentle archive lifecycle — P0

Product semantics:
- stale/unacted new connections may move out of Active after ~48 hours;
- this is a soft archive, not deletion;
- archived relation is recoverable according to server policy.

Client:
- display warning when at risk;
- archive/unarchive actions;
- correct Active/Archived membership;
- do not invent expiry locally;
- chat writeability follows server/chat gatekeeper status;
- cached Active list reconciles immediately after server lifecycle change.

---

# 44. Collaboration session / Click Drops — P0

## 44.1 Trigger
Current behavior may open collaboration session on reconnect/encounter:
- by connection
- by chat/group
- fallback route

## 44.2 Session
- finite collaboration/session window;
- state survives normal navigation;
- expiration closes camera/action availability;
- no stale camera overlay after session expiry.

## 44.3 Camera
Native full-screen camera:
- permission state
- capture
- optional filter
- preview
- retake
- send
- cancel

No camera work when not visible.

## 44.4 Disposable message
Metadata includes `disposable_roll: true` and optional `encounter_id`.
Server stamps reveal/collaboration TTL (current web behavior uses 24h reveal).

Before reveal:
- locked placeholder;
- no plaintext thumbnail leak.

After reveal:
- notification/event can update;
- decrypt/display normal media;
- realtime/refresh resolves state.

---

# 45. Encounter tether — P0 if current iOS surface remains active

Current subsystem includes:
- active multi-tap peers;
- RSSI hints;
- compass direction UI;
- global tether overlay/toast;
- iOS widget / Live Activity bridge.

Native implementation should be cleaner:
- `TetherService` actor owns sensor/session data;
- `TetherPresentationModel` turns it into user-facing direction/distance confidence;
- SwiftUI overlay renders it;
- Widget/Live Activity integration uses native ActivityKit/WidgetKit if retained.

Do not present precise physical direction if the underlying signal is only a coarse hint; preserve current product semantics.

---

# 46. Explicitly removed: calls

**REMOVE / DO NOT PORT**

Do not implement:
- voice call UI
- video call UI
- LiveKit
- CallKit
- PushKit
- VoIP token
- incoming-call push
- call notification toggle
- call menu
- call overlay
- call_log generation from mobile

Legacy `call_log` rows/message types may remain readable if historical data contains them. That is a display-compatibility question, not permission to restore the feature.


---

# 47. Profiles — P0

There must be exactly one canonical person-profile feature and one canonical group-profile feature, regardless of whether entry came from Clicks, Map, Search, Chat, Event Directory, Home, or a notification.

## 47.1 User profile

Current canonical profile tab order:
1. Timeline
2. Media
3. Links
4. Files
5. Beacons
6. Members — group profiles only

The native implementation should preserve the semantic set/order unless the final design deliberately changes it. Older profile documentation that omits Beacons is stale relative to the current `ProfileSheetTab` enum/runtime.

Additional header/data:
- avatar
- name
- relationship/connection state
- shared interests
- personality when current privacy rules allow
- online/availability state where appropriate
- action grid (Message and current relationship actions)
- mutual/friends-in-common information when context permits

Map pin profile and Clicks-list profile must hydrate the same underlying data.

### Canonical routing

```text
Clicks avatar ─┐
Chat header ───┤
Map pin ───────┤
Search ────────┼──> UserProfileView(userID, optional connectionID)
Event directory┤
Home ──────────┘
```

Do not create a second "light profile" with different behavior unless the event directory intentionally requires a privacy-restricted view-only profile. Even then, the restriction should be a presentation policy passed into the canonical feature.

---

## 47.2 Profile Timeline — P0

Timeline can contain:
- first connection moment
- subsequent encounter/reconnect moments
- event association when viewer is eligible
- sensor/context metadata
- user journal entries
- current profile timeline objects from backend

### Journal
- Add
- edit
- delete
- server persistence
- optimistic UI only with rollback
- multiline text
- native keyboard
- stable ordering

### Reconnect update
After a successful BLE/QR reconnect:
- timeline must reflect new encounter without app restart/cache wipe;
- invalidate only the affected connection/profile timeline;
- do not reload unrelated profiles.

### Event privacy
An event title/context is visible on an encounter only when current server/product eligibility allows it. Current behavior attaches `at_event` per reporting user when that user has RSVP **and** an active check-in. Do not infer visibility for every participant merely because one user engaged.

---

## 47.3 Memories / sensor context — P0

Memory Capsules may include:
- location context
- noise
- elevation/barometric context
- weather
- wind
- motion/lux/context where current schema supports it
- subjective context tags

Rules:
- opt-in sensor collection only;
- semantic labels should match current shared normalization;
- exact sensor values should not be fabricated when absent;
- migrated/historical encounters remain readable;
- no expensive sensor sampling outside a relevant encounter flow.

---

## 47.4 Profile Media — P0

A canonical media list derived from authorized/decrypted conversation/profile data.

Required:
- images
- files
- audio where current profile Media includes them
- Click Drop/revealed content as current policy allows
- thumbnails/cache
- fullscreen viewer
- audio controls
- file preview
- no independent gesture system that steals horizontal swipes from tab switching/scrolling

The current bug where audio seek gestures trigger profile tab swipes must be impossible by construction: interactive media controls get gesture priority in their bounds.

---

## 47.5 Profile Beacons — P0

- list event/beacon context linked to the relationship;
- deterministic visual identity matches the same beacon elsewhere;
- tap opens canonical event/beacon detail or focuses map according to current entry semantics;
- viewer eligibility enforced by backend/data layer;
- no duplicate event detail implementation.

---

## 47.6 Profile Links — P0 if current product surfaces it

Display links derived from locally decrypted message/profile content according to current privacy rules.
- native `Link`/URL open behavior;
- validate schemes;
- no arbitrary `javascript:` or unsafe scheme opening;
- empty state;
- do **not** assume the server can derive these links from v2 message plaintext.

## 47.7 Profile Files — P0

The current canonical profile surface includes a distinct **Files** tab; the full current tab set/order is defined in §47.1.

- hydrate from `/api/connections/{connectionId}/tabs` (or current resolver using chat/group identity);
- show filename, type, size/status when available;
- tap -> the canonical decrypted file/Quick Look pipeline;
- download/sign/decrypt once and cache safely;
- group profile uses group/chat-aware resolution and current group crypto material;
- no inert plaintext filename row;
- empty, loading, error, and access-revoked states are explicit.

---

# 48. Group profile — P0

Required:
- canonical group avatar;
- custom group-avatar upload using the current server endpoint `/api/groups/{groupId}/avatar` when the user is authorized;
- generated fallback avatar when no custom image exists;
- server-enforced profile/avatar change cooldown is authoritative (current route applies a 60-second profile-change cooldown);
- name;
- participants;
- **Members** profile tab, using the same canonical per-user profile routing when a member is tapped;
- participant avatars clickable to individual profiles
- same avatar fallback generation used everywhere
- add eligible member
- remove member where authorized
- rename
- leave
- delete where authorized
- group Media if current UI exposes it
- group links/context as current product permits

Membership mutation must coordinate:
1. server membership transaction;
2. chat membership;
3. E2EE v2 epoch rotation;
4. realtime/inbox update;
5. profile UI.

Do not report success after step 1 if the client cannot obtain the new epoch necessary to send.

---

# 49. Nearby / Map architecture — P0 / P1

The map surface must feel native and professional. The existing KMP implementation's layering complexity is not to be copied.

## 49.1 High-level native composition

```text
Map root
├── native map
├── top native navigation/header controls
├── map layer/filter controls
├── zoom/recenter controls only where product needs them
├── connection/hub/beacon annotations
└── native bottom-sheet "Nearby" discovery surface
```

The discovery feed should be a true bottom-sheet/lip presentation rather than a fake second full screen when the final product design calls for that.

Map and discovery are two views over one data model.

## 49.2 `MapFeatureModel`

Own:
- viewport
- user location state
- map mode/layers
- ghost mode
- connection pins
- beacons/events
- hubs
- discovery sections
- selected annotation
- presented detail
- focus intent (`initialBeaconId`, connection, hub)
- nearby match state

Map annotations must be stable by identity so a refresh does not remove/reinsert every pin.

## 49.3 Location permission states
- not determined
- denied
- allowed approximate
- allowed precise
- temporarily unavailable
- stale
- active

Map still renders useful non-location content when location is denied if product permits.

---

# 50. Connection map pins — P0

- one canonical pin per peer/relationship under current map semantics;
- first-meet location remains stable after later encounters when product requires it;
- reconnect must not create duplicate pin;
- tap -> canonical profile/connection sheet;
- Message -> canonical chat;
- online/core/availability decoration uses shared model, not separately fetched map-only state;
- Memory Map toggle behavior preserved; current regression states turning it off must not reduce map to core-only incorrectly.

---

# 51. Ghost Mode — P0

Ghost mode is a product privacy mode, not a disabled-location error.

There are currently **two related pieces of state** that the native rebuild must reconcile rather than conflating:

1. the KMP mobile session Ghost Mode, which is intentionally in-memory and resets on app restart while halting background refresh/new location upload; and
2. `click-web`'s `PATCH /api/user/ghost-mode`, which persists `users.ghost_mode` for event mutual-attendee/privacy behavior.

Before the native implementation is finalized, document the exact server/privacy lifecycle in `BACKEND_CONTRACT_MATRIX.md`. The intended native behavior should preserve the session-scoped user experience while also keeping any server privacy bit from becoming stale across clients. If the server field remains required, enabling/disabling the session mode should update it, and a fresh app session should explicitly reconcile/reset it according to product policy rather than silently leaving yesterday's server value active.

Current expected effects include:
- grayscale/reduced map presentation;
- hide/reduce own presence;
- reduced discovery/background sync according to current backend behavior;
- core connections may remain visible according to current policy;
- no user dot if current design requires it.

Requirements:
- **session-scoped, not durable:** current product deliberately resets Ghost Mode on app restart for safer privacy defaults;
- applies immediately;
- server-facing location/presence behavior changes, not just map styling;
- turning off reconciles state;
- cold launch starts non-ghosted unless the then-current product/backend deliberately changes this policy;
- exact privacy promise documented in Settings;
- no hidden sensor/upload path continues contrary to the mode's stated behavior.

---

# 52. Beacon model — P0

The native model must match the actual current mobile/backend taxonomy rather than inventing a broader enum.

## 52.1 Canonical current beacon kinds

Current `MapBeaconKind` values are exactly:

```text
soundtrack
sos
hazard
utility
study
social_vibe
event
other
```

Swift should model these explicitly while retaining an unknown/raw-value compatibility path so a newer backend kind cannot crash an older client.

Current compatibility parsing also recognizes legacy/alternate values such as:
- `hazard_utility` -> hazard
- strings containing sound / `music` -> soundtrack
- strings containing emergency -> SOS
- strings containing danger -> hazard
- strings containing utility/amenity -> utility
- strings containing study -> study
- strings containing social/vibe -> social_vibe
- strings containing activity -> event

Do not add speculative native enum members such as recreation/transit/swag/capacity/hobby/scavenger unless the then-current backend actually defines them.

## 52.2 Current user-facing creation categories

The current Map FAB / Beacon Drop flow exposes exactly:

```text
Soundtrack
Hazard
Utility
SOS
Study
Event
Hub
```

`Hub` is a separate community-hub creation path, not a `MapBeaconKind` persisted as a normal beacon kind.

## 52.3 Shared beacon properties

Properties may include:
- id
- creator
- title
- description
- kind/category
- coordinate
- location name/address
- image
- deterministic generated visual seed/input
- visibility audience
- TTL/lifecycle
- show-creator-name flag
- event fields
- soundtrack fields
- engagement state
- hub linkage where current APIs expose it

Decode metadata defensively because historical rows may use legacy key names or serialized JSON forms.

---

# 53. Deterministic generated beacon visuals — P0

The same beacon must have the same generated fallback visual across:
- map pin
- Home card
- Explore/Event tile
- share-to-chat card
- Search result
- profile Beacons row
- detail header
- web where parity is required

Do not call random color/pattern selection at render time.

Implement:
```text
BeaconVisualDescriptor = deterministic function(beacon stable fields/visual seed)
```

Swift implementation needs golden fixtures against `click-web` / current mobile behavior.

An uploaded image overrides fallback where current design does so.

---

# 54. Beacon creation — P0

One canonical creation sheet/flow.

## 54.1 Shared fields
Depending on kind:
- category/type
- title
- description
- duration/TTL
- visibility audience
- display-creator-name choice
- location
- optional photo

Current beacon TTL chips are exactly:

```text
15 min
30 min
45 min
1 hour
90 min
2 hours
3 hours
6 hours
24 hours
2 days
3 days
4 days
5 days
6 days
7 days
```

The current mobile UI intentionally offers up to 7 days even though the backend can cap/accept a broader maximum. Preserve the current user-facing choices unless product changes them.

Photo is **optional for every category** per current regression expectations. A missing image uses deterministic generated visual.

### Photo controls
Real buttons:
- Take photo
- Photo library
- preview
- Replace
- Remove

Compression:
- use current backend max/format semantics;
- current KMP docs mention auto-compress to <= 2 MB for beacon upload;
- preserve unless backend route currently specifies a different limit.

## 54.2 Form stability
- soundtrack URL stays one row if intended;
- placeholders cannot accidentally enlarge a single-line field;
- keyboard does not create a bottom black gap;
- switching beacon/event modes does not flash to wrong sheet height;
- date/time picker does not move surrounding form geometry unexpectedly.

## 54.3 Location
Events require a location:
- address search
- Use my location
- no requirement that creator physically be at future venue
- store normalized location_name/formatted_address/current coordinates

## 54.4 Event-specific creation — P0

The current KMP creation sheet already exposes the following and the native rebuild must preserve them:

### Schedule
- start/end
- current timezone semantics
- inline schedule validation
- date/time picker does not shift surrounding form layout unexpectedly

### Fixed event category taxonomy
Exactly:
- `Promotional`
- `Social`
- `School Event`

### Check-in area / venue scale
Current exact mapping:

| UI label | API value | default radius |
|---|---|---:|
| Intimate | `intimate` | 75 m |
| Neighborhood | `neighborhood` | 250 m |
| Venue | `venue` | 750 m |
| Campus | `campus` | 2500 m |

`Neighborhood` is the current default.

The server/current shared resolver clamps an explicit check-in radius to **25–5000 m**. The client may display the named presets, but the backend remains authoritative for actual check-in acceptance.

### Event location
- address search
- `Use my location`
- selected location required
- creator does not need to physically be at a future venue
- guests still require current location for attendance check-in

### Map visibility audience
Current creation choices:
- Everyone
- Connections only
- Core connections only

This controls map-pin audience and is separate from event-page listing visibility.

### Event-page listing options
Current creation UI already includes:
- **Public**
- **Unlisted**
- **Invite-only**
- optional positive **Capacity**
- **Approval required**
- guest list visibility:
  - **Public**
  - **Hosts only**

These are **P0 parity**, not post-parity enhancements.

Current model also contains `cover_theme_id`, but no verified current KMP creation control was found for it. Treat cover-theme authoring as P2/web-owned unless it becomes reachable before cutover.

### Creator identity
Current sheet includes `Display my name` / `Show your name on the map pin for others nearby.` Preserve the privacy choice and server field semantics.

### Photo
Optional, using the same shared beacon image pipeline.

### Guest-list paste/match
Creator guest-list paste/match remains P0 where the current mobile creator flow exposes it; this is distinct from the event-page guest-list visibility setting above.

## 54.5 Soundtrack-specific
Preserve:
- URL parsing
- track/artist/preview/art metadata if current backend resolves it
- open original music service with validated URL

## 54.6 Submit
- validate client UX requirements;
- backend is final validator;
- pending prevents double submit;
- success inserts/upserts map model without full reload;
- failure retains draft and media.

---

# 55. Beacon detail — P0

Canonical detail used wherever appropriate.

Header:
- generated/uploaded visual;
- category chip;
- title appears once;
- schedule/location appears once;
- avoid duplicated header/detail text.

Actions depend on kind:
- Share link
- Share to chat
- Navigate
- Bookmark
- RSVP
- Check in/out
- open music
- open hub
- creator edit/delete

All entry points should hydrate the same engagement state.

---

# 56. Events — P0

Events are specialized beacons with durable engagement and event-linked social context.

## 56.1 Event detail data
- event identity
- title;
- description using the current safe markdown-capable rendering semantics rather than reducing existing formatted descriptions to raw markdown text;
- schedule
- location/address; if old/current rows contain only generic `Current location` plus coordinates, resolve a human-readable label through the current geocoding/BFF strategy without blocking the rest of the detail;
- host/creator identity when `showCreatorName`/current visibility policy allows it;
- posted/created time where current detail displays it;
- categories
- venue scale/check-in radius
- image/generated visual
- creator
- RSVP
- bookmark
- check-in
- engagement counts
- directory eligibility/data
- linked hub/chat
- ticketing status when P2 is enabled

## 56.2 RSVP
- fetch current state;
- RSVP;
- cancel;
- optimistic UI allowed with rollback;
- state persists server-side;
- linked event chat access follows current authorization policy.

Current mobile/server models include event listing policy that the first version of this spec did not enumerate:

```text
event_visibility: public | unlisted | invite_only
event_capacity: positive integer | null
approval_required: boolean
guest_list_visibility: public | hosts_only
cover_theme_id: string | null

request_status:
  pending
  approved
  denied
  waitlisted
```

P0 native event detail must correctly represent the response state:
- ordinary event -> `RSVP / Sign Up`;
- approval-required event -> `Request to join`;
- pending -> approval-request status, not "RSVP succeeded";
- full/waitlisted -> waitlist/list state using server response;
- cancel must cancel the current RSVP/request semantics returned by the backend;
- event chat remains unavailable until the user has the authorization state accepted by the event-chat resolver.

The current KMP creator UI **does expose** event visibility, capacity, approval-required, and guest-list visibility, so creating/editing those is **P0 PARITY**. `cover_theme_id` exists in the model/backend but no verified current KMP creation control was found; cover-theme authoring remains **P2 NEW NATIVE / web-owned** unless it becomes reachable before cutover.

Current event/hub behavior: **RSVP can grant event hub/chat participation without requiring physical check-in**, while check-in is a separate attendance/geofence state. Do not incorrectly make check-in a prerequisite if current server policy authorizes RSVP members.

## 56.2.1 Canonical event-chat resolver — P0

Do not trust a cached `hub_id` carried in event presentation metadata.

Before opening event chat, call:

```text
GET /api/beacons/{beaconId}/event-chat
```

Current response resolves:
- `event_id`
- canonical server-authorized `hub_id`
- title
- creator_id

Map failures into bounded UI states:

```text
200 -> Ready
403 -> Requires RSVP/authorized event membership
404 -> Event/chat unavailable
409 -> Event chat relation not ready; explicit retry
410 -> Event chat ended
401 -> refresh session once, then explicit retry/error
other -> retryable error
```

The CTA must never enter an implicit infinite loading/retry loop.

## 56.2.2 Event teaser / "Seed a Room" — REMOVE FROM NATIVE APP

Current KMP main still renders an event-teaser card with the literal chip **`Seed a Room`** and also contains an `Event teasers` notification preference. This is stale relative to the current product decision that Seed Room is website-only.

For `click-ios`:
- do **not** port the `Seed a Room` card/CTA;
- do not add a native Seed Room creation or seeding flow;
- do **not** surface the `Event teasers` notification toggle: the current database migration explicitly documents `event_teaser_push_enabled` as gating **pre-event Seed-a-Room teaser pushes**;
- retain defensive parsing of an incoming legacy `event_teaser` push during the migration window so an old server job cannot crash the new app; route its `beacon_id` to ordinary Event Detail or ignore it safely, but do not recreate Seed Room UI;
- coordinate backend cleanup/disablement of Seed-a-Room teaser delivery for the native release;
- web public-event/Seed Room experiences remain web-owned.

## 56.3 Bookmark
- server-backed;
- persists force-kill/sign-in;
- appears in Settings Saved Events;
- optimistic toggle with rollback.

## 56.4 Check-in
Full-width labelled action:
- `Check in here`
- `Checked in` / equivalent current copy

Flow:
1. user taps;
2. prevent double tap;
3. request/use location;
4. submit server validation;
5. optimistic or pending state;
6. success -> checked in;
7. failure -> revert + precise reason.

Failure cases:
- location denied
- too far/geofence reject
- check-in window not open
- event ended
- server error

Current expected pre-live copy includes concept "Check-in opens when the event starts."

Server owns geofence truth.

## 56.5 Share
Native share:
- public/universal URL;
- Share to chat -> target picker -> canonical beacon/event message card;
- no duplicate event serialization.

## 56.6 Navigation
Use system maps/action sheet as chosen product behavior.
Do not silently send the user's current location to a third party beyond the navigation action.

---

# 57. Event people directory — P0

Every signed-in viewer allowed by current server policy can open the event directory.

Sort/filter modes:
- A–Z
- Interests
- Mutuals

Requirements:
- relationship-aware rows;
- friends-in-common/mutual counts;
- "Mutuals here" section as current behavior;
- do not duplicate mutual users again under Everyone if current design excludes them;
- sort chip change scrolls list to top;
- no large blank region at full detent;
- profile tap -> canonical profile with a restricted/view-only policy for friend-of-friend where product forbids direct connect;
- list uses stable IDs and lazy rendering.

Privacy/server response decides what fields a viewer receives.

---

# 58. Event guest list — P0 if current creator feature remains active

Creator-only:
- paste/import guest list as current UI permits;
- submit;
- match;
- status/progress;
- error state;
- privacy-safe handling.

Backend routes represented in mobile API:
- guest list status
- post guest list
- match guest list

Do not surface creator controls to ordinary attendee.

### Approval-request administration — WEB-OWNED / P2

The current mobile creator can make an approval-required event and attendees can enter pending/waitlisted states, but no verified current KMP call site for the organizer `/rsvp/requests` approve/deny API was found. Organizer approval management remains web-owned for parity unless it becomes reachable before cutover. Do not invent a second approval model in Swift.

---

# 59. Event reminders — P0

Current product reminder classes include:
- day-of
- one-hour-before

Integration:
- in-app Home card;
- standard push notification;
- Saved Events/event engagement state.

**Do not use EventKit for Click event reminders.** The current calendar module is read-only and exists for availability/free-busy (§81). Click does not automatically create OS calendar events for beacon RSVPs.

Use stable reminder identity so refresh/re-registration cannot create duplicate Click reminders.

---

# 60. Event-linked encounter — P0

When users connect/reconnect at an event:

- each reporting user's event attachment eligibility is evaluated independently;
- current expected eligibility: RSVP + active check-in;
- persist event identity/context on encounter through authoritative backend;
- profile Timeline displays exact event title for eligible viewer;
- profile Beacons can open event;
- non-engaged viewer must not gain event context simply because another user was eligible.

This needs cross-user integration tests.

---

# 61. Community Hubs — P0

## 61.1 Hub lifecycle
Current regression expects created hubs to be permanent rather than automatically disappearing after 24h unless a newer backend policy supersedes this.

Features:
- create
- discover
- join
- active membership
- chat
- edit if owner
- leave
- delete if owner

## 61.2 Create
Fields:
- name
- category
- location/geofence details according to backend
- event linkage when applicable

Use `/api/hub/create` / current routes.

## 61.3 Join
From map:
1. hub detail;
2. location/geofence verification if required for non-event hub;
3. server join/access;
4. open Hub chat.

Event-linked hub authorization may use event host/RSVP/active check-in according to current server rules. Never duplicate this policy in Swift.

## 61.4 Deep links
Support current:
- `click://hub/{id}`
- universal link equivalent

Queue through auth/onboarding if needed.

## 61.5 Leave/delete/edit
- native action menu;
- confirmation for destructive;
- owner-only edit/delete;
- leave removes active row and tears down realtime;
- delete removes/finalizes current navigation safely.

---

# 62. Hub chat — P0

Use common conversation primitives, but preserve hub differences.

Required:
- realtime message list
- current E2EE v2 for upgraded event hubs / appropriate current hub protocol
- composer
- no arbitrary timed cooldown; current regression states rapid sends are allowed for nonempty drafts
- access lock state
- geofence/access revalidation
- settings
- empty lobby

Out-of-geofence current concept:
- "No longer near hub…" style reason
- do not mislabel as expiration

Do not show direct-chat read receipt semantics if hub protocol does not support them.

Critical regression:
First entry after time away must not paint previous-day/stale conversation and then flicker it away. Key all cached hub timelines by exact hub/chat identity plus current authorized context, and validate cache before painting.

---

# 63. Nearby discovery feed — P0/P1

The discovery sheet/feed may include:
- events
- hubs
- beacons
- nearby connection-related signals
- availability-intent matches
- relevant category sections

Rules:
- only real available categories/counts;
- stable sections;
- map selection and list selection point to same model;
- dragging sheet and scrolling list use system arbitration;
- search field must not compress while typing;
- switching layer/filter updates both map and list coherently.

---

# 64. Availability — P0

## 64.1 Availability intent
Create short-lived intent:
- activity preset/custom current domain
- day/time
- optional detail
- current TTL (docs/regression use 24 hours)

Actions:
- create
- edit
- delete with confirmation
- display active intents
- expire server-side

## 64.2 Free This Week
Settings toggle/surface:
- local cached state
- authoritative server state
- failure not represented as valid false if server fetch failed

## 64.3 Mutual availability
For connections:
- display overlap only from valid server/data result;
- if overlap fetch fails, do not silently imply no overlap;
- action can route to chat/planning.

## 64.4 Match alerts
- push/in-app when backend determines match;
- routing to relevant person/intent;
- dedupe;
- preference controls.

---

# 65. Me / Settings — P0

The fifth root tab is user-facing **Me**, while the internal/deep-state route remains `settings` for compatibility. The root reads as the user's account/identity home; preference subpages are Settings.

One native hierarchy.

## 65.1 Profile header
- avatar
- display name
- edit name
- edit avatar
- account identity where appropriate

## 65.2 Availability
- Free This Week
- active availability intents
- edit/delete/create

## 65.3 Alerts
Current mobile should expose valid current notification categories only.

The reviewed current Settings surface contains:
- **Message notifications**
- **Event reminders**
- **Event teasers** — **REMOVE FROM NATIVE SETTINGS**; current backend schema explicitly defines these as Seed-a-Room teaser pushes (§56.2.2)
- **Reconnect nudges**
- **Availability matches**
- **Hub messages**
- **Ambient sound enrichment** — sensor/enrichment opt-in; requests microphone contextually when enabling

Do **not**:
- expose a call notification toggle merely because old UserDefaults has one.

Each server-backed notification preference must:
- hydrate independently of OS authorization;
- save to the current preference API;
- revert UI and show an error if persistence fails;
- gate corresponding push sender behavior server-side, not only suppress banners on-device.

Changing notification preference:
- update server;
- request OS authorization only after user intent and when needed;
- if OS permission denied, explain and link to system Settings;
- do not toggle UI to a false "enabled" state when OS prevents delivery.

## 65.4 Privacy & data

The current mobile Settings surface has four independent product toggles:

- **Ghost Mode** — session-scoped; halts/reduces sync and presence according to current implementation.
- **Location snap** — `location_connection_snap_enabled`; controls whether GPS is captured at tap/connection time. Enabling can trigger the contextual location permission flow and permission hints.
- **Memory Map** — `location_show_on_map_enabled`; current semantics do **not** hide non-core map pins. It influences personal/list-sort/Remember-Me behavior rather than acting as a map visibility filter.
- **Business insights** — `location_include_in_insights_enabled`; controls eligibility for anonymized venue/business aggregate data.

These toggles remain independently enabled; do not force Memory Map or Business Insights off merely because Location snap is off.

Also include:
- current visibility/privacy controls;
- any data export/account controls supported by the current backend;
- accurate business-insights explanation;
- no accidental opt-in during KMP migration.

## 65.5 Interests
Edit same taxonomy/domain as onboarding.
- at least 5 if still required by product;
- save;
- rollback/error.

## 65.6 Personality
- exactly 5;
- helper exactly current product copy (`Pick exactly 5 traits.`);
- no stale login-gate explanation.

## 65.7 Saved Events
- server-backed bookmarks;
- cold-start hydration;
- tapping card -> canonical Event Detail;
- no no-op.

## 65.8 Appearance
- dark mode current behavior;
- system/default mode if product adds it;
- no Photo pile setting — §20.2.1 is authoritative and Home is linear-only;
- ignore the retired legacy `home_layout_mode` for product behavior;
- imported still-valid appearance preferences;
- no one-off color overrides that break design system.

## 65.9 Memory Capsule opt-ins
- ambient noise
- barometric/elevation context
- any other current sensor opt-ins
- persistence
- no sensor starts merely because toggle screen is visible

## 65.10 Calendar
- explanatory permission
- EventKit authorization
- current mutual-free-time features
- system Settings redirect on denial
- no full calendar upload if product promise is local analysis.

## 65.11 Permissions Hub
Show current platform authorization status:
- location
- Bluetooth where inspectable
- microphone
- camera
- photos
- contacts
- calendar
- notifications

Actions:
- request only if not determined and appropriate;
- otherwise open app Settings.

## 65.12 Web dashboard
Open `CLICK_WEB_BASE_URL`/current site using authenticated or ordinary browser flow according to existing product; never embed auth token in query string.

## 65.13 Sign out
Confirmation if current UX requires.
Then execute full logout sequence from §17.

## 65.14 Delete account — P0 RELEASE REQUIREMENT

The current KMP Settings UI does not expose this, but `click-web` already has `DELETE /api/user/delete`, and the native app supports account creation. The production native app must provide an easy-to-find way in Settings to initiate full account deletion.

Important backend compatibility issue discovered during verification:
- the existing `/api/user/delete` route authenticates through **web cookies** (`createServerClient` + `cookies()`), not the native Bearer-JWT route helper;
- therefore the Swift app must **not** assume it can call the current route with `Authorization: Bearer`;
- before release, either:
  1. make the deletion endpoint safely accept the standard native authenticated route contract, or
  2. provide a direct account-deletion webpage and open that exact page from Settings.

Deletion flow:
- explain permanence/data implications;
- require deliberate confirmation/reauthentication as appropriate;
- initiate full account deletion rather than mere deactivation;
- on confirmed completion, clear local auth/cache/crypto session state;
- if the account used Sign in with Apple, coordinate the required Apple token revocation in the backend/account-deletion design;
- display pending/completed status if server deletion is asynchronous.

---

# 66. Safety — P0

Safety is not merely a UI action sheet; it must alter ability to interact.

## 66.1 Block
- confirmation
- server block
- update local connection/chat state
- peer cannot continue allowed message/access behavior according to backend gatekeeper
- remove/suppress presence and suggestions where policy requires
- navigate out safely if currently inside blocked conversation

## 66.2 Report
- reason/category if current backend supports it
- submit
- success
- optional block follow-up
- no duplicate submission from double tap
- no raw report text in analytics logs

## 66.3 Remove connection
- confirmation
- current permanent/relationship removal backend semantics
- cleanup inbox/cache
- historical data handling follows server policy

## 66.4 Group member removal
- authorized role only
- confirmation
- membership update
- E2EE epoch rotation
- realtime update

## 66.5 Beacon delete
Creator-authorized:
- confirm
- server delete
- dismiss detail
- remove from map/list

---

# 67. Push notifications — P0

## 67.1 Transport
iOS: **standard APNs only**.

No PushKit/VoIP.

## 67.2 Current push category contract

The reviewed current `send-push-notification` Edge Function defines exactly these mobile categories:

```text
chat_message
archive_warning
disposable_reveal
event_reminder
event_teaser
reconnect_nudge
shared_upcoming_event
availability_match
hub_message
```

`incoming_call` is explicitly rejected and must remain unsupported.

Current server preference mapping:

| Push category | Governing preference |
|---|---|
| `chat_message` | `message_push_enabled` |
| `archive_warning` | `message_push_enabled` |
| `disposable_reveal` | `message_push_enabled` |
| `event_reminder` | `event_reminder_push_enabled` |
| `event_teaser` | `event_teaser_push_enabled` — legacy Seed-a-Room category; parse defensively during migration, do not expose native preference/UI (§56.2.2) |
| `reconnect_nudge` | `reconnect_nudge_push_enabled` |
| `shared_upcoming_event` | `reconnect_nudge_push_enabled` |
| `availability_match` | `availability_match_push_enabled` |
| `hub_message` | `hub_message_push_enabled` |

The native notification router should parse these into typed destinations rather than treating every non-event payload as a generic chat.

Current iOS tap behavior provides compatibility guidance:
- `event_reminder` / `event_teaser` + `beacon_id` -> Event Detail;
- `shared_upcoming_event` + `beacon_id` -> Event Detail;
- `chat_message` with `chat_id` / `connection_id` -> canonical chat;
- hub/availability/reconnect payloads should route using the concrete identifiers supplied by the current sender/backend contract rather than guessing from display text.

Unknown future `type` values must fail safely to a neutral app launch or generic destination rather than crash.

## 67.3 Token registration
- request OS permission contextually;
- obtain APNs device token;
- upload through `POST /api/user/push-tokens`;
- send `platform = "ios"`;
- send `token_type = "standard"` only; do not register a VoIP token;
- include the app's stable per-install `device_id` so the server can prune stale rows for the same `(user_id, device_id, token_type)`;
- handle token arriving before auth by securely queueing it;
- flush after login;
- update on token rotation;
- tolerate server upsert-on-token semantics;
- logout/user-switch must not replay a queued token for the wrong user.

## 67.4 Foreground behavior
If current chat is open:
- suppress duplicate banner as current policy dictates;
- still update timeline/inbox;
- clear delivered notification when thread read.

If another destination:
- show appropriate in-app/system behavior.

## 67.5 Notification routing
Notification response -> typed `PendingRoute`.

Examples:
- chat -> Clicks stack -> chat
- hub -> hub
- disposable reveal -> relevant chat/media
- event reminder -> canonical Event Detail / focus
- archive warning -> relevant connection

Do not make notification handling mutate navigation from a background callback outside MainActor.

---

# 68. Notification Service Extension — P0

Responsibilities:
- inspect payload;
- decrypt eligible message preview;
- modify title/body safely;
- fall back to privacy-safe generic copy;
- finish within extension time limit;
- no network dependency required for basic fallback;
- never crash notification delivery because crypto payload is unknown/new.

Version payloads. Unknown crypto version -> generic preview, not drop.

---

# 69. Offline and connectivity — P0 HARDENING

## 69.1 Global offline status
Native unobtrusive banner/state:
- offline
- reconnecting
- online

Do not cover interactive chrome.

## 69.2 Cached read surfaces
At minimum:
- Home
- Clicks
- recent chat
- relevant map summary
- Settings preferences

Show stale/offline state where material.

## 69.3 Chat offline send
- local message ID;
- encrypted queued payload or safely reproducible draft according to crypto protocol;
- persisted pending operation;
- retry when online;
- exactly-once/idempotent semantics;
- visible failed/pending state.

Do not retain plaintext message draft in an insecure general log/cache.

## 69.4 Proximity offline queue
Migrate/currently preserve:
- pending connection queue
- pending proximity handshake queue

On network recovery:
- only replay for same user;
- honor server expiration;
- stop on permanent validation error;
- user-visible outcome.

## 69.5 Reconnect
Connectivity restoration should:
- refresh session if needed;
- rebind realtime;
- flush pending operations;
- selectively invalidate stale data;
- not refetch every screen indiscriminately.

---

# 70. Privacy and business-insights data — P0

Click's encounter graph can feed anonymized business insight products only under the intended opt-in/policy.

Native client must preserve:
- `include_in_business_insights`/equivalent preference semantics;
- no accidental default opt-in during migration;
- sensor/location collection boundaries;
- no plaintext contacts;
- no plaintext encrypted chat;
- no raw tokens/keys in telemetry.

Any analytics/telemetry event containing user/location IDs must be reviewed for necessity and retention policy before implementation.

---

# 71. App telemetry — P1 HARDENING

The old app has a variety of connection telemetry; the native rebuild should preserve useful product signals but avoid uncontrolled instrumentation.

Create `TelemetryService` with a small documented event catalog.

Potential events:
- app launch duration
- auth restore outcome category
- route transition duration
- handshake started/factor readiness/result
- QR redeem result category
- chat initial paint latency
- send latency
- realtime reconnect
- event detail load
- check-in result category
- sheet/nav hitch diagnostics
- backend request performance

Rules:
- no message plaintext
- no file contents
- no contact plaintext
- no auth token
- no E2EE key
- no continuous fine location unless specifically part of authorized product telemetry
- stable event names documented in `Docs/TELEMETRY.md`

Instrumentation must not block user interaction.

## 71.1 Existing map-friction telemetry — P0 BEHAVIORAL PARITY

The current mobile app already has a defined, privacy-constrained telemetry flow. Preserve its semantics unless deliberately redesigned:

```text
begin map session(coarse hexbin)
record map pan
record meaningful action (beacon/connect/etc.)
record QR fallback
end/background session
 -> POST /api/telemetry/friction when eligible
```

Current privacy/behavior constraints:
- no raw coordinates in the HTTP body;
- coarse anonymized `hexbin_id` only;
- no flush without auth;
- nonblocking/background work;
- session duration >= 30s and at least one pan before anomaly flush;
- session resets after successful/attempted eligible flush according to current policy.

Current user-visible anti-doomscroll behavior:
- after roughly **4 minutes** of map use with no meaningful action and a pan within the last **45 seconds**, show the gentle grass nudge;
- dismiss sticks for the rest of that map session;
- a meaningful action suppresses it;
- this is a real current user flow and belongs in the parity ledger, not just telemetry plumbing.

## 71.2 Existing connection-flow telemetry — P0 DATA-COMPATIBILITY

Preserve the current separation from map friction:

```text
POST /api/telemetry/connection-flow
```

Current client funnel includes states such as:
- started
- awaiting_selection
- failed
- host_selection_abandoned
- reconnect_rate_limited
- recovery timeout/incomplete
- clique blocked
- matched
- pending
- offline_queued
- host_selection_confirmed
- reconnect saved
- recovery success
- clique created
- proximity_at_event_attached / skipped

Do not add user IDs or raw GPS to this payload. Preserve current success-path sampling/failure-always-send intent unless telemetry policy is deliberately revised. Map-friction events and connection-flow events remain separate server streams.

---

# 72. Clicktivities / achievements — AUDIT BEFORE SURFACING

Current code contains `ClicktivitiesScreen` / `ClicktivityCard` and docs mention achievements/stats.

Before implementing a visible native feature:
1. determine if the screen is reachable in the current shipping iOS navigation;
2. determine whether backend data is real or hardcoded/demo;
3. determine current product decision.

If reachable/product-active -> port as P0.
If latent/dead/mock -> do not expose in new app merely for "parity."

Stats already legitimately used by Home/profile should still be implemented through their actual surfaces.

---

# 73. Business / waitlist / venue QR — AUDIT

Current regression docs mention:
- waitlist dialog if entry exists
- venue QR with `venue_id`

These are not automatically first-class native flows.

During backend contract audit:
- identify current reachable entry;
- preserve venue QR parsing if used in production;
- keep marketing waitlist web-owned unless native entry is actually active.

---

# 74. Ticketed events — P2 NEW NATIVE

The backend foundation already exists. This is explicitly post-parity unless product prioritizes it into the first release.

## 74.1 Architecture
Payments stay server/Stripe-owned.

Native app:
- displays organizer/buyer state;
- opens server-generated hosted Stripe Checkout in secure system browser/web auth context;
- never creates final paid ticket locally;
- waits for server/webhook truth;
- polls/subscribes to order state as appropriate.

## 74.2 Organizer Stripe Connect
Backend:
- `POST /api/payments/connect/onboarding`
- `GET /api/payments/connect/status`

Native flow:
1. explain payout onboarding;
2. request onboarding URL;
3. open Stripe-hosted onboarding;
4. return;
5. re-fetch server status;
6. allow paid tier/sales controls only when backend reports eligible.

Do not infer completion from browser redirect alone.

## 74.3 Ticket tiers
- list
- create/edit as server permits
- inventory
- price
- sales window
- status

Use:
- GET/POST event ticket tier endpoints.

## 74.4 Enable ticket sales
Explicit organizer status operation.
Backend remains source of truth.

## 74.5 Buyer checkout
1. choose tier/quantity;
2. POST checkout;
3. receive hosted Checkout URL/order;
4. open;
5. on return, fetch order;
6. show pending until webhook finalizes;
7. success -> ticket wallet/event state.

Never mark paid based solely on client redirect.

## 74.6 Tickets/credential
- ticket list for event/user
- display credential/QR
- no client-generated credential authenticity
- offline display only if server-signed credential supports it

## 74.7 Check-in
Organizer/scanner:
- scan credential;
- POST check-in;
- idempotent duplicate handling;
- valid/already-used/refunded/invalid states;
- haptic feedback;
- scanner remains high-throughput.

## 74.8 Refund
Authorized organizer:
- order detail;
- refund action;
- server/Stripe;
- webhook/reconciliation;
- attendee RSVP remains independent where backend specifies.

---

# 75. Native visual system

The visual direction should use the current Click product identity, but this rewrite must not copy old implementation quirks.

## 75.1 Tokens
Define:
- semantic colors
- typography
- spacing scale
- radii
- separators/strokes
- material hierarchy
- avatar sizes
- control heights
- icon sizes

Avoid "glass" as a custom effect abstraction. When the current iOS SDK offers native material/Liquid Glass behavior, use the platform API with availability fallback.

## 75.2 Canonical components
Only create shared components where repetition is real:

- `UserAvatar`
- `ConnectionAvatar`
- `ClickAsyncImage`
- `EmptyState`
- `ErrorState`
- `OfflineBadge`
- `StatusPill`
- `PrimaryAction`
- `EventVisual`
- `MessageBubble`
- `AttachmentBubble`
- `AudioMessageBubble`
- `AvailabilityChip`
- `PersonRow`

Do not create a giant `ClickCard` used for everything if the information architecture differs.

## 75.3 Avatar generation
One fallback algorithm:
- deterministic from user/group identity;
- same visual across Home, list, group profile, chat, event directory;
- custom image overrides;
- cached image loading;
- correct accessibility label.

---

# 76. Accessibility — P0 QUALITY

Every feature must pass an iOS accessibility sweep before cutover.

## 76.1 VoiceOver
- meaningful button labels
- decorative icons hidden
- reaction summaries
- message sender/content grouping
- image alt/current fallback
- event state and check-in state announced
- map provides alternate/list access
- QR screen conveys expiration/action text
- progress does not spam announcements

## 76.2 Dynamic Type
- no clipped header actions
- no fixed-height form text that cuts content
- chat composer expands within reasonable bounds
- event action layout adapts
- Settings rows remain readable
- onboarding can scroll

## 76.3 Reduce Motion
- remove nonessential transforms
- system navigation remains appropriate
- connection reveal simplifies
- no loss of state communication

## 76.4 Increase Contrast / Reduce Transparency
Use semantic platform colors/material fallbacks.

## 76.5 Touch targets
Meet Apple minimums. Visual glyph can be smaller; hit area cannot.

## 76.6 Switch/keyboard input
Important dialogs/sheets/forms must be operable without gesture-only actions.

---

# 77. Localization and copy

Even if English is the only launch language, user-facing copy should use string catalogs from the start.

Do not localize:
- IDs
- debug diagnostics
- backend enum keys

Do localize:
- buttons
- errors
- permission explanations
- dates/times
- event/check-in status
- empty states

Use `FormatStyle` for:
- dates
- relative time
- counts
- distances
- currency for ticketing

Never hand-format currency with string concatenation.

---

# 78. Date/time correctness

Store/transport:
- ISO-8601/backend timestamps
- absolute `Date`

Display:
- user's locale/time zone unless event specifies venue/local semantics;
- event schedule must be consistent with web;
- relative message timestamps do not rewrite every row every second.

Use one date parser capable of current Postgres timestamp variants if API DTOs are not normalized server-side. Prefer normalizing API contracts rather than duplicating permissive parsing everywhere.

---

# 79. Media/image pipeline

`ImagePipeline` responsibilities:
- URL cache policy
- deduplicated in-flight fetch
- downsample to target display size
- off-main decode
- memory cache with bounded cost
- disk/system URL cache where safe
- cancellation
- privacy-safe handling for decrypted chat media

Do not put decrypted private chat images into a globally shared URL cache.

Use a separate `MediaVault` for private content.

---

# 80. Audio session coordination

One service coordinates:
- ultrasonic handshake
- voice-note record
- voice-note playback
- other media playback

State changes must:
- stop incompatible activity
- restore previous appropriate category/mode
- handle interruption
- route changes
- background/foreground

The app must never leave an ultrasonic audio mode active and then break voice-message playback/recording.

---

# 81. Calendar integration — P0

The current Click calendar contract is narrower and more privacy-preserving than a generic calendar integration.

Apple EventKit is used **read-only for availability/free-busy**, not for Click event reminders.

Required behavior:

- request EventKit access contextually from Settings or the first availability flow that needs it;
- current iOS implementation requests read access; Click must never create, edit, or delete the user's calendar events;
- fetch a rolling **7-day** free/busy window by default;
- retain only start/end busy intervals required for overlap math;
- keep calendar event titles/details on-device;
- do not upload raw calendar titles, locations, notes, attendees, or other event metadata;
- calendar changes invalidate/recompute derived availability;
- denied/restricted state degrades gracefully and offers system Settings;
- local calendar reads remain possible in Ghost Mode, but broadcasting a Click availability intent remains subject to the normal upstream privacy/sync policy.

Current Click **event-beacon reminders are a separate `events/` feature**:
- they do not read the device calendar;
- Click does not automatically add an RSVP'd event to Apple Calendar;
- Click's event reminder push/in-app scheduling must not be described as EventKit synchronization.

If a future product feature explicitly adds "Add to Calendar," specify it separately rather than quietly expanding this privacy boundary.

---

# 82. Contacts integration

Prior Connections:
- use `CNContactStore`;
- normalize phone/email deterministically;
- SHA-256;
- dedupe hashes;
- batch request within backend limits;
- never log raw values;
- release raw contacts after hashing/use;
- permission denied -> skip/manual continuation.

Unit-test normalization with international numbers and casing/whitespace emails consistent with backend.

---

# 83. Map navigation and external URL safety

Any external action:
- maps navigation
- music service
- web dashboard
- Stripe Checkout
- shared link

must validate scheme/host as needed.

Music link helper should accept known HTTPS/deep-link patterns and use system URL handling; do not accept arbitrary code-bearing schemes.

---

# 84. Error presentation

Error policy:
- inline for form field errors
- banner/toast for transient recoverable action
- dedicated error state when screen cannot function
- alert only for blocking/destructive/system-sensitive cases

Never present:
- raw SQL
- raw JWT
- Supabase stack
- URLSession NSError dump
- crypto key material

Debug logging can contain safe request IDs and endpoint names.

---

# 85. Global feedback

Native equivalents for:
- compact toast/banner
- offline status
- loading shimmer/skeleton
- tether toast
- action success/failure

One overlay coordinator at app scope for genuinely global transient feedback. Feature-local feedback stays local.

Do not stack multiple toast systems.

---

# 86. Data consistency rules

## 86.1 Optimistic mutations
Allowed where rollback is straightforward:
- reaction
- bookmark
- check-in UI pending
- RSVP
- archive/core toggle
- message local-send item

Require:
- mutation ID
- rollback/reconciliation
- server refresh on ambiguous timeout

## 86.2 Identity
Never use array index as identity for:
- messages
- conversations
- events
- attendees
- media
- map pins

## 86.3 Cache invalidation
Invalidate by affected domain key, not global cache clear.

Examples:
- new encounter -> connection + timeline + map summary
- reaction -> message only
- bookmark -> event + Saved Events
- RSVP -> event + directory/hub access + reminders
- profile avatar -> user cache everywhere
- group membership -> group + chat + crypto epoch

---

# 87. Security requirements

## 87.1 Secrets
- no service-role Supabase key in app;
- no Stripe secret;
- no APNs signing key;
- anon/public client keys may be bundled as intended;
- build configuration secrets excluded where actually secret.

## 87.2 Keychain
Use Keychain for:
- auth refresh/access session material
- device E2EE private identity
- other cryptographic secrets

Use correct accessibility classes.

## 87.3 Logs
Redact:
- Authorization
- cookies
- tokens
- password
- message plaintext
- private attachment URL if sensitive
- encryption material
- contact hashes if linkable and unnecessary

## 87.4 ATS
Do not weaken App Transport Security globally for development convenience.

## 87.5 Web views/browser auth
Prefer system browser/auth session.
If an embedded web view is required, isolate domain allowlist and navigation.

---

# 88. Concurrency and cancellation

Every screen-bound async operation needs cancellation semantics.

Examples:
- search task cancels on query change;
- profile load cancels on dismissal;
- event directory sort cancels old request if new sort supersedes it;
- chat remains subscribed while destination active; task is cancelled on exit;
- map fetches coalesce viewport changes rather than spawning unbounded requests.

Actors/services must not retain feature models after view lifecycle ends.

---

# 89. Realtime channel budget

Maintain explicit inventory in diagnostics.

Potential channels:
- global presence
- inbox changes
- active chat messages/reactions
- active chat typing/presence
- active hub
- map/discovery if backend uses realtime
- event state only when detail active

Do not subscribe one channel per inbox row.

Expose a debug-only inspector showing:
- topic
- state
- auth token generation/version
- subscriber feature
- retry count

This will make future realtime/auth bugs much easier to diagnose.

---

# 90. Testing strategy

The new app requires tests at four levels.

## 90.1 Pure unit tests
Fast, no network:
- route parsing
- auth state machine
- legacy KMP token decode
- onboarding step computation
- contact normalization/hash
- date parsing
- beacon visual deterministic fixtures
- connection grouping
- availability state
- message list merge
- scroll-anchor calculations if custom
- crypto vectors
- media metadata
- deep-link queues
- error mapping
- pending operation retry policy

## 90.2 Repository/API contract tests
Against mocks/fixtures:
- every endpoint DTO
- error envelope
- 401 -> refresh -> retry
- refresh failure
- cancellation
- idempotency
- pagination
- realtime event mapping

Prefer captured/golden JSON fixtures from current backend.

## 90.3 UI tests
XCUITest for:
- unauthenticated launch
- login/signup toggle
- onboarding
- tabs
- Home
- search
- My QR
- scanner permission
- Clicks tabs
- chat composer
- message action
- media viewer
- profile
- Settings
- Event Detail
- hub
- ghost mode
- sign out
- deep link

Tests should assert user-visible semantics, not fragile exact pixel coordinates.

## 90.4 Hardware integration
Required for:
- APNs
- BLE
- ultrasonic
- multi-device proximity
- camera
- microphone
- QR
- location
- event check-in
- App Clip
- performance
- Keychain migration
- E2EE cross-device

---

# 91. Hardware test matrix

Maintain `Docs/HARDWARE_TEST_MATRIX.md`.

Minimum pre-cutover scenarios:

## 91.1 One-device
- cold/warm launch
- KMP -> native update session migration
- all tabs
- forms/sheets
- camera
- QR display
- notification permission
- denied permissions
- map
- event creation
- Settings
- offline mode

## 91.2 Two iPhones
- new Tri-Factor connect
- repeat/reconnect
- QR connect
- realtime direct chat
- typing
- read/delivery
- reaction
- reply
- edit/delete
- photo
- file
- audio
- offline sender -> reconnect
- E2EE v2 upgrade/message
- block/report
- collaboration reveal
- tether if supported

## 91.3 iPhone native + existing Android/KMP
This is essential because Android remains on the old client.

Test both directions:
- native iOS -> Android connection
- Android -> native iOS connection
- direct chat v1 historical read
- v2 message write/read
- attachment
- reaction
- presence
- QR
- Tri-Factor
- group membership
- push

## 91.4 Three+ devices
At least:
- two iPhones + Android
- three iPhones where possible

Test:
- Multi-Tap
- host selection
- <=12 cap logic
- verified clique
- membership on every device
- group E2EE epoch
- remove/add member
- realtime inbox appearance

## 91.5 Event/hub
Two/three accounts:
- RSVP
- non-RSVP
- check-in
- far-away reject
- directory visibility
- linked hub access
- hub message
- leave
- event encounter visibility per user

---

# 92. Performance test gates

A PR affecting a hot surface must attach device evidence when appropriate.

## Chat
- rapid 10-second scroll recording
- first open
- keyboard
- media
- back gesture

## Home
- cold first paint
- first scroll
- refresh

## Map
- pan/zoom
- sheet expand/collapse
- annotation selection

## Media
- open/close
- seek audio
- image zoom

Record:
- device
- OS
- build config
- instruments summary when debugging regressions

Do not merge an animation fix validated only in Simulator if the bug is frame pacing on physical iPhone.

---

# 93. Backend contract verification process

Before implementing each feature, the agent must:

1. read relevant current `click` feature/repository;
2. read relevant `click-web` route;
3. read current migration/RLS if authorization is nontrivial;
4. write/update `BACKEND_CONTRACT_MATRIX.md`;
5. create Swift DTO fixture tests;
6. then implement UI.

Do not guess API shape from a Kotlin DTO alone if the server has changed.

---

# 94. Parity ledger format

`Docs/PARITY_LEDGER.md` must contain a row for every flow.

Suggested columns:

| ID | Flow | Old iOS entry | Backend | Native entry | States implemented | Automated | Device-tested | Classification | Notes |
|---|---|---|---|---|---|---|---|---|---|

A flow is not "done" because a screen exists.

`done` requires:
- entry reachable;
- success;
- loading;
- empty if applicable;
- error;
- offline if applicable;
- cancellation/back;
- auth refresh;
- analytics/privacy;
- accessibility;
- device test where hardware-sensitive.

---

# 95. Detailed regression ledger to port from current app

The native project should translate the current cross-platform regression checklist into iOS-native assertions. At minimum preserve the following.

## Shell
- cold startup gating
- all five tabs
- tab reselect
- nested back
- deep route history
- offline banner
- overlays do not leak
- search dismissal preserves underlying tab

## Auth
- email sign in
- OAuth
- signup
- forgot password
- invalid credentials
- logout
- offline boot
- token refresh
- process death

## Onboarding
- ProfileBasics
- Welcome
- Interests >=5
- Personality exactly5
- Avatar upload/skip
- Prior Connections/skip
- returning account no incorrect onboarding flash

## Connect
- QR valid/invalid/expired
- My QR
- share
- App Clip
- Tri-Factor
- single pair
- 3+ selection
- duplicate prevention
- offline queue
- reconnect
- tags
- event attachment
- sensor capture
- reveal

## Clicks
- active/groups/archive
- no duplicate reconnection
- core
- unread
- presence
- group
- hub
- create clique
- actions
- profile

## Chat
- history
- text
- offline
- typing
- delivery/read
- scroll
- keyboard
- reply
- long press
- reactions
- copy
- edit
- delete
- forward
- photo
- file
- audio
- media
- group
- no call UI
- vibe/icebreaker
- archive warning
- Click Drops
- tether
- loading/error
- push open

## Home
- greeting
- search
- event
- explore
- availability
- reconnect
- recent
- reminders
- recap/insights
- refresh

## Map
- location
- pins
- reconnect no duplicate
- hubs
- beacons
- map/list parity
- filters
- ghost mode
- bottom sheet
- intent match
- chat/profile routing

## Events
- create
- address
- schedule
- image optional
- deterministic fallback
- detail
- RSVP
- bookmark
- check-in
- far reject
- denied location
- pre-live reject
- directory
- mutuals
- guest list
- share
- reminders
- saved event
- profile event context

## Hubs
- create
- persistence
- join
- geofence/access
- link
- realtime
- rapid sends
- leave
- edit
- delete
- cache correctness

## Availability
- post
- edit
- delete
- free this week
- expiration
- overlap/match

## Settings
- profile
- interests
- personality
- notifications
- ghost
- sensors
- calendar
- saved events
- appearance
- permissions
- web
- logout

## Security
- connection schema semantics
- QR 90 seconds
- server proximity rules unchanged
- vibe-check expiry
- E2EE compatibility
- no secrets logs
- safe logout

---

# 96. CI/CD for `click-ios`

Keep CI intentionally shorter than the KMP project's recent multi-hour iOS path.

On PR:

1. Swift format/lint if adopted (changed files; no massive legacy baseline)
2. build app for iOS Simulator
3. build NotificationService
4. build App Clip
5. unit tests
6. crypto fixture tests
7. selected deterministic UI smoke
8. static secrets scan

Avoid:
- building the same archive twice under different names;
- exhaustive hardware-like UI flows in every PR;
- long serial test matrices with duplicated coverage.

Nightly/pre-release:
- larger UI suite
- backend staging integration
- performance smoke if infrastructure exists.

Release:
- Archive once
- signing validation
- entitlements validation
- bundle IDs validation
- export/upload/TestFlight through chosen pipeline

CI target: common PR feedback should remain practical rather than reproducing the old 1–2 hour iOS regression problem.

---

# 97. Debug tooling

Debug builds should have a hidden internal diagnostics surface, not release user UI.

Useful panels:
- session state (redacted token metadata only)
- token expiry timestamp
- last refresh/result
- realtime channel list/health
- connectivity
- cached user ID
- pending operation counts
- proximity sensor status
- active audio mode
- push token registered yes/no (redacted)
- current E2EE device ID/public-key fingerprint only
- active epoch IDs, never keys
- feature flags
- API base URL
- recent request IDs/error categories

This dramatically lowers future debugging cost without contaminating production UX.

---

# 98. Feature flags

Use server/config-backed flags only where real staged rollout is needed.

Candidate flags:
- ticketing
- new proximity implementation rollout
- optional experimental map surfaces
- new chat transition if risky

Do not feature-flag basic parity indefinitely.

Feature flag state must have:
- default
- source
- last update
- safe fallback

---

# 99. Migration implementation phases

The rebuild should be executed as vertical slices and remain runnable at every phase.

## Phase 0 — Repository/bootstrap

Create:
- `click-ios`
- Xcode project
- main target
- App Clip target
- Notification Service target
- configs
- README/AI
- design tokens
- app environment/router
- CI
- empty typed backend client
- signing identities configured locally/CI

Acceptance:
- app builds/runs;
- same bundle ID;
- targets sign;
- no feature code copied wholesale from KMP.

## Phase 1 — Session compatibility + auth

Implement:
- legacy KMP Keychain import
- legacy preferences import
- session controller
- email auth
- OAuth/Apple
- refresh/retry
- root gate
- ProfileBasics

Acceptance:
- update install keeps user signed in;
- expired token refresh works;
- realtime can later consume refreshed token;
- logout clean.

## Phase 2 — Onboarding + shell + Settings skeleton

Implement:
- Welcome
- Interests
- Personality
- Avatar
- Prior Connections
- permission coordinator
- five-tab native shell
- profile/settings basics

Acceptance:
- brand-new user reaches Home;
- returning user never sees wrong gates.

## Phase 3 — Read-only Home/Clicks/Profile

Implement:
- cached app snapshot model
- Home sections
- Clicks list/segments
- presence
- profile/timeline
- search foundation

Acceptance:
- core app is navigable and data-authentic;
- no write mutation yet beyond profile/settings.

## Phase 4 — Direct chat first vertical slice

Implement end-to-end:
- E2EE compatibility
- direct message list
- send
- realtime
- read/delivery
- typing
- keyboard
- reply/reaction/edit/delete
- APNs route
- Notification Service

This phase receives disproportionate performance scrutiny.

Acceptance:
- native iOS <-> Android interoperability;
- legacy history readable;
- v2 current writes compatible;
- chat feels materially better than KMP client.

## Phase 5 — Chat media + profiles

Implement:
- photo
- file
- audio
- media vault
- fullscreen viewer
- profile Media
- group profile foundation

Acceptance:
- no gesture conflicts;
- no upload state leakage across chats;
- correct encryption.

## Phase 6 — Connections / QR

Implement:
- Add Click
- My QR
- scanner
- deep links
- App Clip
- connection tags
- reconnect
- reveal
- archive/core/actions
- safety

Acceptance:
- iOS <-> Android QR;
- existing connection reconnect does not duplicate.

## Phase 7 — Tri-Factor + Multi-Tap

Implement:
- BLE
- ultrasonic
- GPS
- pending recovery
- offline queue
- multi-peer selection
- verified clique
- E2EE group rotation
- tether

Acceptance:
- 2-device and 3+-device hardware matrices.

## Phase 8 — Map / beacons / events

Implement:
- map
- discovery sheet
- pins
- ghost
- beacons
- create
- event detail
- engagement
- directory
- guest list
- reminders
- Saved Events

Acceptance:
- canonical event behavior from all entries;
- no map/chat state leakage;
- smooth map/sheet interaction.

## Phase 9 — Community hubs

Implement:
- discover
- create
- join
- access/geofence
- hub chat
- settings
- deep links
- cache correctness

Acceptance:
- first open after stale day never flickers old chat;
- event-linked access correct.

## Phase 10 — Availability / collaboration / remaining parity

Implement:
- availability
- overlap
- match alerts
- Click Drops
- archive warnings
- remaining settings
- latent reachable features confirmed by ledger

## Phase 11 — Parity freeze

Stop feature expansion.

- run full parity ledger;
- resolve missing reachable behavior;
- accessibility;
- offline;
- session recovery;
- migration;
- crypto;
- hardware;
- performance.

## Phase 12 — TestFlight shadow release

Existing KMP app remains reference.

Use internal/external TestFlight cohorts as appropriate.

Compare:
- auth
- notifications
- connection creation
- chat
- event access
- crash/hang
- frame pacing
- backend error rates

Do not dual-write to a separate data model. Both clients must use the same production/staging contract.

## Phase 13 — Production replacement

Upload native build to existing App Store Connect app.

Release checklist:
- bundle ID exact
- entitlements exact
- associated domains
- App Clip association
- Notification Service
- privacy manifests if required by dependencies
- export compliance
- APNs
- OAuth redirects
- universal links
- staged rollout
- rollback plan

---

# 100. Cutover and rollback

Because the native build uses the same App Store record/database, rollback can be another binary version, but data/wire compatibility matters.

Rules:
- no native-only irreversible database migration without Android/web compatibility;
- server changes deployed ahead of client must be backward compatible during migration window;
- new message/encryption protocol write must be readable by remaining Android/current clients;
- feature flags can stop risky new-native-only features server-side;
- keep the KMP iOS release branch buildable for at least the migration validation window.

A rollback build must not become unable to read data generated by the native client.

---

# 101. App Store Connect cutover checklist

No new app record.

Before upload:

- [ ] existing app record selected
- [ ] bundle `compose.project.click.click`
- [ ] team `W4C3V9Z2N4`
- [ ] valid distribution signing
- [ ] build number greater than existing
- [ ] marketing version intentional
- [ ] App Clip target correctly embedded
- [ ] Notification Service correctly embedded
- [ ] associated domains correct
- [ ] Sign in with Apple entitlement correct
- [ ] standard APNs entitlement correct
- [ ] no PushKit/VoIP
- [ ] usage descriptions accurate
- [ ] privacy manifests/declarations current
- [ ] encryption export answer reviewed
- [ ] universal links verified on production domain
- [ ] App Clip experience verified
- [ ] OAuth callback verified
- [ ] notification service on release-signed build
- [ ] TestFlight update over old KMP build preserves session
- [ ] TestFlight update over old KMP build preserves/decrypts historical messages
- [ ] pending KMP queue migration tested

---

# 102. Agent implementation rules

These rules are deliberately strict because the current app accumulated debt partly through agents solving local symptoms without respecting architecture.

1. **Read before editing.** Read this spec, feature source in `click`, relevant backend route in `click-web`, and existing Swift feature code.
2. **One vertical slice at a time.**
3. **No fake data in production paths.**
4. **No TODO implementation that silently returns success.**
5. **No swallowing errors with empty catch.**
6. **No server rule duplication without written justification.**
7. **No refactor of unrelated feature while implementing a slice.**
8. **No generic abstraction before demonstrated reuse.**
9. **No animation patch that masks a state-ownership bug.**
10. **No manually delayed UI to "feel smooth."**
11. **No blocking main actor for crypto/media/network.**
12. **No destructive database/schema changes from the iOS repo.**
13. **No modifying `click-web` contract casually to fit the client; coordinate and document any backend change.**
14. **No new dependency without rationale.**
15. **No call feature.**
16. **No dropping legacy crypto reads.**
17. **No changing bundle/App IDs.**
18. **No new App Store product.**
19. **No merge without tests for state machine/business-critical behavior.**
20. **No claiming parity without updating the ledger.**

---

# 103. Coding conventions

Prefer readable direct Swift.

Good:

```swift
@Observable
@MainActor
final class EventDetailModel {
    private let eventID: BeaconID
    private let events: EventRepository

    var state: LoadState<EventDetail> = .loading
    var mutation: EventMutation?

    func load() async { ... }
    func toggleBookmark() async { ... }
    func rsvp() async { ... }
    func checkIn() async { ... }
}
```

Avoid:

```text
BaseViewModel<
  GenericPaginatedMutableResource<
    EventDetailEntity,
    EventDetailDTO,
    EventDetailCoordinator
  >
>
```

Protocol boundaries belong at real system seams:
- repository
- auth provider
- realtime provider
- sensor/hardware provider
- storage
- crypto
- push

They do not belong around every trivial helper.

---

# 104. Naming conventions

Use product language consistently:

- Clicks = relationship/inbox concept
- Click = individual connection action/product brand as current copy dictates
- verified clique = internal/domain term; user-facing group naming should follow current product copy
- Nearby = user-facing map/discovery root if final design retains it
- Beacon = broad map object
- Event = event-kind beacon
- Hub = community/event chat location
- Encounter = physical connection/reconnect record
- Memory Capsule = user-facing encounter context
- Click Drop = collaboration/disposable roll

Do not introduce new synonyms in Swift that fragment analytics/API vocabulary.

---

# 105. Definition of done for one feature

A feature is complete only when all applicable categories are satisfied:

### Functional
- normal success
- loading
- empty
- error
- retry
- cancellation
- navigation
- deep link/push if relevant

### Data
- correct endpoint
- correct authorization
- server truth respected
- cache
- invalidation
- realtime
- offline where relevant

### Security
- sensitive data handled correctly
- encryption if relevant
- logs redacted
- permissions contextual

### Native interaction
- scroll
- keyboard
- gesture
- sheet
- back
- haptics
- accessibility

### Performance
- Release device tested
- no obvious hitch
- no excessive requests/subscriptions
- image/media work off-main

### Compatibility
- Android/web
- legacy data
- old iOS update state if relevant

### QA
- unit tests
- fixture/contract tests
- UI test when stable/value-add
- manual device evidence for hardware paths

---

# 106. Full native-rebuild acceptance criteria

The `click-ios` build may replace the KMP iOS build only when:

1. Existing App Store/TestFlight users update in place under the same bundle/app identity.
2. A valid KMP Keychain session is migrated or reused without forced login.
3. Server-resolved onboarding prevents incorrect gate flashes.
4. All currently reachable P0 flows are implemented or deliberately removed by current product decision.
5. Voice/video call UI remains absent.
6. Android interoperability is verified for connection and chat.
7. Legacy v1 encrypted messages/media required by history remain readable.
8. E2EE v2 direct/group/hub compatibility passes cross-client fixtures.
9. Push notification routing works on release-signed physical devices.
10. App Clip invokes the supported connection flow.
11. Universal/custom links survive auth/onboarding gating.
12. QR remains compatible with current 90-second server token protocol.
13. Tri-Factor works on physical devices and remains server-validated.
14. Multi-Tap works across 3+ devices.
15. Repeat encounters do not duplicate relationships/map pins.
16. Chat text/media/audio are stable, scoped, and performant.
17. Chat scroll/keyboard/navigation show no systematic stutter under Release profiling.
18. Event RSVP/bookmark/check-in/directory/hub access matches server truth.
19. Map/discovery sheet uses coherent native gestures.
20. Ghost mode matches stated privacy behavior.
21. Settings accurately reflects current notification/privacy/sensor state.
22. Offline boot and recovery do not fabricate empty data or corrupt queues.
23. Accessibility baseline passes.
24. The full parity ledger has no unexplained P0 gaps.
25. A TestFlight upgrade from the latest KMP build has been exercised end-to-end.
26. Rollback compatibility is documented.

---

# 107. First implementation PR recommended scope

The first PR in `click-ios` should be intentionally infrastructure-only and small enough to review deeply.

Include:

- Xcode project
- main Click target
- App Clip target shell
- Notification Service target shell
- exact bundle IDs/entitlements
- configuration files
- app icon/assets migration
- `AppEnvironment`
- `AppRouter`
- `RootGateView`
- `SessionController` protocol/skeleton
- `ClickAPIClient`
- `LegacyKMPStateMigrator` with real Keychain `com.click.auth/session_v2` decoding test
- `SettingsStore` capable of reading `click_auth_prefs`
- basic design tokens
- CI build/test
- architecture docs copied from this spec into repo
- no Home/chat/map implementation yet

Acceptance:
- builds on simulator/device;
- signs using the existing App ID;
- proves it can read a test legacy Keychain session fixture;
- no old KMP code linked;
- no speculative architecture beyond the seams above.

The second PR should complete real auth/session restoration. The third should implement the onboarding/shell vertical slice. This ordering makes it difficult to accumulate UI work on top of a broken auth/session foundation.

---

# 108. Source map for implementers

This specification was derived from the current product repositories. Before implementing, revisit the current version of each source because the repositories may advance.

## `click`
Primary references:

```text
README.md
AI.md
EXTERNAL_SETUP.md

docs/ui-ux/mobile/00-INDEX.md
docs/ui-ux/mobile/01-design-system.md
docs/ui-ux/mobile/02-shell-navigation.md
docs/ui-ux/mobile/03-auth.md
docs/ui-ux/mobile/04-onboarding-gates.md
docs/ui-ux/mobile/05-home.md
docs/ui-ux/mobile/06-connect-handshake.md
docs/ui-ux/mobile/07-connections-inbox.md
docs/ui-ux/mobile/08-chat.md
docs/ui-ux/mobile/10-map-beacons-hubs.md
docs/ui-ux/mobile/11-search.md
docs/ui-ux/mobile/12-profile-memories.md
docs/ui-ux/mobile/13-availability.md
docs/ui-ux/mobile/14-settings-privacy.md
docs/ui-ux/mobile/15-collaboration-drops.md
docs/ui-ux/mobile/16-safety.md
docs/ui-ux/mobile/17-global-feedback.md

docs/regression-testing/01-full-checklist.md
current September 2026 stabilization/polish docs

composeApp/.../data/api/ApiClient.kt
composeApp/.../data/repository/*
composeApp/.../crypto/README.md
composeApp/.../crypto/CRYPTO_README.md
composeApp/.../notifications/README.md
composeApp/.../proximity/README.md
composeApp/.../encounter/README.md

composeApp/src/iosMain/.../data/storage/TokenStorage.ios.kt

iosApp/iosApp/Info.plist
iosApp/iosApp/iosApp.entitlements
iosApp/ClickClip/*
iosApp/NotificationService/*
iosApp/Configuration/Config.xcconfig
```

## `click-web`

```text
AI.md
lib/connections/README.md
lib/chat/README.md
lib/map/README.md
docs/ticketing.md

app/api/connections/*
app/api/qr/*
app/api/chat/*
app/api/beacons/*
app/api/hub/*
app/api/payments/*
app/api/orders/*

lib/server/proximity/*
supabase/migrations/*
relevant Edge Functions/RLS
```

## `click-split-app`

Architecture reference:

```text
Sources/ClickSplit/App/AppEnvironment.swift
Sources/ClickSplit/App/AppRouter.swift
Sources/ClickSplit/App/ClickSplitRootView.swift
Sources/ClickSplit/Domain/Services/SessionStore.swift
Sources/ClickSplit/Data/Supabase/SupabaseClient.swift
Sources/ClickSplit/DesignSystem/*
Sources/ClickSplit/Features/*
```

Use its Swift patterns selectively. Do not couple repositories.

---

# 109. Final architectural rule

The new iOS client should be conceptually simple:

```text
Click's backend owns truth.
Swift repositories translate truth.
Feature models own screen state.
Native views own presentation.
Apple owns interaction physics.
```

The old iOS app should be treated as a comprehensive behavioral test oracle, not as an architecture template.

If an implementation decision makes the new client require custom synchronization between multiple rendering/navigation systems merely to achieve standard iOS behavior, reconsider the decision. The primary technical reason for `click-ios` is to eliminate that class of complexity while preserving the mature product/backend behavior Click has already accumulated.


---

# 110. `NfcScreen` naming compatibility — NO CoreNFC dependency

The current source audit resolves an important naming ambiguity.

`NfcScreen` is a **legacy class/screen name for Tap to Connect**. The current iOS proximity implementation uses:

```text
CoreBluetooth
+ ultrasonic AVAudioSession/audio processing
+ progressive Core Location
```

The current repository search found:
- no `CoreNFC` import;
- no `NFCReader` / `NFCNDEF` implementation;
- no `NFCReaderUsageDescription`;
- no NFC entitlement in the iOS app;
- current proximity documentation explicitly describes `NfcScreen` as BLE + ultrasonic + progressive GPS.

Therefore `click-ios` must **not add CoreNFC or an NFC entitlement merely because old file names/regression wording say NFC**.

Native implementation:

```text
User-facing Tap to Connect
        |
        v
Tri-Factor coordinator
  BLE + ultrasonic + progressive GPS
        |
        v
server-authoritative proximity validation
```

Compatibility obligations:
- preserve historical rows whose `connectionMethod`/metadata says `nfc`;
- accept legacy analytics/data vocabulary where necessary to read old records;
- do not claim NFC itself verifies current connections;
- if CoreNFC is deliberately added to the product in a future branch, treat that as a new capability requiring entitlement, usage-description, hardware, protocol, and App Review analysis—not as parity work.

This section overrides stale regression text such as "iOS NFC read path functional."

---

# 111. Premium subscription / paywall — AUDIT BEFORE SURFACING

A search of the reviewed current `click` source did not identify a stable StoreKit/RevenueCat subscription implementation, product-ID contract, or durable premium entitlement domain. The term "premium" is also used extensively in the project to describe **product feel**, which must not be confused with a paid plan.

Therefore:

- do not invent a StoreKit paywall as part of this rebuild;
- before parity freeze, search the then-current branches for any newly merged subscription/paywall implementation;
- if a real paid plan exists by implementation time, add it to `BACKEND_CONTRACT_MATRIX.md` and `PARITY_LEDGER.md` with:
  - StoreKit product IDs;
  - entitlement source of truth;
  - purchase;
  - restore;
  - transaction verification;
  - server sync;
  - family/refund/revocation behavior;
  - feature gating;
  - offline entitlement behavior;
  - App Store Server Notification integration where applicable.
- UI feature gating must never trust an unverified local boolean.

This section prevents an agent from either omitting a later-added real monetization flow or fabricating one from the phrase "premium feel."

---

# 112. Completeness rule for repository drift

This document is intentionally comprehensive against the reviewed September 2026 repositories, but `click`, `click-web`, and `click-split-app` can continue changing while `click-ios` is implemented.

At the beginning of every implementation phase:

```text
git fetch current main branches
        |
        v
diff relevant feature/backend folders since spec baseline
        |
        +-- new reachable user flow? -> add to PARITY_LEDGER + this spec
        |
        +-- retired flow? -> mark REMOVE with source
        |
        +-- contract change? -> update BACKEND_CONTRACT_MATRIX + fixtures
        |
        +-- no semantic change -> proceed
```

A stale specification is not authority over newer deliberate product/backend behavior. Conversely, an isolated experimental file on a newer branch is not automatically a shipping requirement. Reachability and current product guidance must be established.

The final pre-cutover audit must enumerate **all reachable screens/routes/actions in the then-current KMP iOS build** and prove each maps to one of:

- implemented in `click-ios`,
- intentionally removed by current product decision,
- web-only by design,
- Android-only by design,
- post-parity feature explicitly feature-flagged off.

No reachable current iOS flow may be omitted silently.


---

# 113. Verification audit: backend-only/current-web event surfaces

A second mechanical audit compared this spec against the complete current `click-web/app/api/**/route.ts` tree. Several routes exist that are **not current KMP iOS parity**. They are explicitly classified here so an agent does not silently omit them or accidentally make them P0.

## 113.1 Public unauthenticated event microsite — WEB-OWNED

Current web routes include:

```text
GET  /api/beacons/public-events
GET  /api/beacons/{id}/public
POST /api/beacons/{id}/rsvp/guest
GET  /api/beacons/{id}/rsvp/guests          # organizer
GET/POST /api/beacons/{id}/rsvp/requests    # organizer approval/deny
GET  /api/beacons/{id}/summary?token=...
```

Disposition:
- the unauthenticated public event microsite and guest-without-Click-account RSVP remain **web-owned** for parity;
- the installed app must still handle its advertised `/e/{beaconId}` Universal Link correctly for signed-in Click users;
- do not accidentally break guest web access by assuming every public-event URL should require native authentication;
- if organizer guest management is later promoted into native, treat it as **P2 NEW NATIVE**, using the existing backend rather than inventing a second guest model.

## 113.2 Organizer event recap / network analytics — WEB-OWNED / P2

Current web routes include:

```text
GET  /api/beacons/{id}/recap               # participant
GET  /api/beacons/{id}/recap-summary       # organizer
GET  /api/beacons/{id}/network-health      # organizer
POST /api/beacons/{id}/summary/publish     # organizer
```

These are not current KMP mobile parity and should not delay the first native replacement. If a native organizer dashboard is later desired, build it as P2 against these routes.

## 113.3 Legacy/alternate map APIs

Current web retains:

```text
GET  /api/map/beacons
GET  /api/map/beacons/{id}
POST /api/map/drop
```

`POST /api/map/drop` is an alias to the beacon create path. Native code should use one canonical repository API and not duplicate beacon creation behavior just because aliases exist.

## 113.4 Encounter detail route

`GET /api/encounters/details/{encounter_id}` exists on web but has no verified current mobile call site in the audited KMP client. Treat it as an available backend read, not automatic P0 UI. If Timeline/Memory implementation needs richer encounter detail, add the route to the contract matrix and use it rather than direct service-role-style table access.

## 113.5 LiveKit route is stale for mobile

`click-web` still contains `/api/livekit/token`. This does **not** override the authoritative mobile decision in `click/AI.md`: calls are removed from mobile. `click-ios` must not add call UI or LiveKit merely because the backend route still exists.

---

# 114. Verification audit: exact current Settings parity

The first version of this document described Settings semantically but omitted several exact current user-facing controls. The parity ledger must contain individual rows for:

```text
Availability
  Free currently
  active availability post
  Share/Edit intent
  Remove intent

Alerts
  Message notifications
  Event reminders
  Event teasers              # REMOVE; Seed-a-Room-only legacy preference
  Reconnect nudges
  Availability matches
  Hub messages
  Ambient sound enrichment

Privacy & data
  Ghost Mode
  Location snap
  Memory Map
  Business insights
  Permissions Hub

Profile/preferences
  Interests
  Personality
  Saved events

Appearance
  Dark mode
  # Photo pile home was removed; do not port

Account
  Sign out
  Delete account             # native-release requirement, §65.14
```

Current user-facing label is **`Free currently`** even though legacy storage/model names still include `free_this_week`. Keep storage compatibility separate from product copy.

---

# 115. Verification audit: screen inventory disposition

The current `commonMain/ui/screens` inventory was compared against the native master flow list.

Explicit dispositions for files that otherwise look like missing native screens:

- `LocationOnboardingScreen` — **legacy, do not restore as active full-screen onboarding**.
- `PermissionsOnboardingScreen` — **legacy, do not restore as active full-screen onboarding**.
- `TestingScreen` — **debug/internal only**; native diagnostics replace it, never a release navigation destination.
- `ClicktivitiesScreen` — **AUDIT BEFORE SURFACING**; only its own definition was found in current code search, with no verified production call site.
- `SavedEventDetailSheet` — **covered by canonical Event Detail**; do not create a second native event-detail implementation.
- `CommunitySoundtrackBeaconDetail` — **covered by canonical non-event Beacon Detail**, retaining soundtrack/community/hazard/SOS/utility/study semantics.
- `UnifiedSearchSheet` + `GlobalSearchScreen` — **covered by one native global-search feature**.
- chat split files (`ChatViewHeader`, `ChatViewTimelinePane`, overlays, primitives, etc.) — implementation decomposition only; all user-visible flows remain under the canonical Chat sections.
- current `Seed a Room` event card — **REMOVE FROM NATIVE**, per §56.2.2.

---

# 116. Verification result and remaining pre-implementation checks

After the corrections above, every **verified reachable current KMP iOS screen family**, every current mobile API-wrapper domain, every iOS platform integration, and every current `click-web` route family has one of the required dispositions: P0 parity/compatibility, P1 quality/hardening, P2 new native, web-owned, audit-before-surfacing, legacy-read compatibility, or do-not-port.

The only category that cannot be frozen permanently in a static document is **future repository drift**. Therefore §112 remains mandatory: immediately before each implementation phase and again before cutover, mechanically diff the then-current `click` and `click-web` trees against `PARITY_LEDGER.md`.

This verification also resolved repository contradictions by applying the source-precedence rule rather than blindly copying older docs. In particular, the July Home/photo-pile docs are stale: the September stabilization record and runtime code establish linear-only Home.

This verification specifically closed omissions around:
- stale Home photo-pile/list documentation correctly classified as removed; current Home is linear-only;
- Location snap;
- Memory Map;
- exact notification preferences;
- Profile Files;
- group avatar upload;
- event listing/approval/waitlist states;
- canonical event-chat resolution;
- `/e/{beaconId}` Universal Links;
- exact QR compatibility aliases and `venue_id`;
- the existing App Store numeric ID;
- exact E2EE v2 iOS Keychain identity coordinates;
- map friction/grass-nudge telemetry;
- connection-flow telemetry;
- account deletion;
- public guest RSVP/web event surfaces;
- organizer event recap/network-health route disposition;
- stale Seed Room mobile UI;
- stale LiveKit backend route disposition;
- exact current beacon-kind and creation taxonomy;
- exact beacon TTL choices;
- exact event-category taxonomy;
- event-page visibility/capacity/approval/guest-list creator controls;
- exact venue-scale radii and default;
- current `Map` and `Me` tab naming with the stable `settings` compatibility route;
- Me-tab live profile-photo icon behavior;
- current linear Home content hierarchy;
- organizer RSVP approval management classified as web-owned/P2 unless reachability changes;
- exact current profile tab order including Beacons and group-only Members;
- `event_teaser_push_enabled` conclusively classified as legacy Seed-a-Room behavior and removed from native Settings.


---

# 117. Verification audit: current mobile API-wrapper surface

The final verification pass enumerated every `/api/...` route referenced by the current KMP mobile API wrappers and assigned it to a domain already specified above. This table is a **coverage proof**, not a recommendation to copy the Kotlin networking architecture.

| Current mobile route family | Native disposition |
|---|---|
| `/api/beacons`, `/api/beacons/{id}` | §52–58 Beacon/Event repositories |
| `/api/beacons/{id}/attendees/directory` | §57 Event directory |
| `/api/beacons/{id}/bookmark` | §56.3 Bookmark |
| `/api/beacons/{id}/check-in` | §56.4 Check-in |
| `/api/beacons/{id}/engagement` | §56 Event detail state |
| `/api/beacons/{id}/event-chat` | §56.2.1 canonical event-chat resolver |
| `/api/beacons/{id}/guest-list`, `/guest-list/match` | §58 creator guest list |
| `/api/beacons/{id}/impressions` | telemetry/engagement; nonblocking |
| `/api/beacons/{id}/rsvp` | §56.2 RSVP/request/waitlist |
| `/api/beacons/{id}/share` | §56.5 share analytics/action |
| `/api/beacons/image` | §54 beacon image pipeline |
| `/api/chat/attachments`, `/attachments/sign` | §37 encrypted attachments |
| `/api/chat/devices`, `/api/chat/epochs` | §36 E2EE v2 device/epoch protocol |
| `/api/chat/media` | §37 encrypted media |
| `/api/chat/messages` + read/delivered/unread/update/delete variants | §31–35 chat |
| `/api/chat/reactions` | §33.4 reactions |
| `/api/chat/search` | §21/search + encrypted-search constraints |
| `/api/chats/{id}/collaboration-session` | §44 Click Drops |
| `/api/cliques/members` | §30 group membership |
| `/api/connections/{id}/collaboration-session` | §44 |
| `/api/connections/{id}/event-recommendation` | §27 |
| `/api/connections/{id}/tabs` | §47 Profile tabs |
| `/api/connections/archive`, `/unarchive`, `/core`, `/hide` | §29 connection actions |
| `/api/connections/encounter` | §25 reconnect encounters |
| `/api/connections/prior/request`, `/prior/respond` | §19.13 Prior Connections |
| `/api/connections/proximity`, `/proximity/confirm` | §23–24 Tri-Factor/Multi-Tap |
| `/api/contacts/discover` | §19.13 contact-hash discovery |
| `/api/groups/{id}/avatar` | §48 group profile |
| `/api/hub/{id}` + create/leave/nearby | §61 hubs |
| `/api/hub/devices`, `/api/hub/epochs` | §62/§36 hub E2EE v2 |
| `/api/hub/media`, `/messages`, `/messages/{id}`, `/reactions` | §62 hub chat |
| `/api/insights/widget-vibe` | §20 Home insights |
| `/api/me/event-bookmarks`, `/{id}/teaser` | §20/§56 Saved Events; teaser subject to Seed Room disposition |
| `/api/me/nudges` + dismiss/snooze/acted actions | §29.6 inbox nudges |
| `/api/me/recap` | §20.3 recap |
| `/api/ping` | diagnostics/health only |
| `/api/profile/timeline` | §47.2 Timeline/journal |
| `/api/safety/report` | §66 Safety |
| `/api/user/avatar` | §19.12/§65 profile avatar |
| `/api/user/preferences` | §65 Alerts/privacy preferences |
| `/api/user/push-tokens` | §67.3 APNs token registration |
| `/api/users/{id}/profile`, `/public-profile` | §47 canonical profile |
| `/api/waitlist` | §73 audit/web/business compatibility |

The audit also compared the much broader `click-web/app/api/**` tree. Routes with no current mobile call site were explicitly classified elsewhere as web-owned, P2, compatibility-only, or audit-before-surfacing rather than silently being treated as missing parity.

---

# 118. Verification audit: current iOS platform capabilities

The current native/KMP iOS source was also checked independently of feature documentation.

Verified current native substrates:
- CoreBluetooth for proximity;
- AVAudioSession/audio path for ultrasonic proximity and media;
- Core Location with When-In-Use authorization;
- Core Motion / CMAltimeter for opted-in encounter context;
- EventKit read-only free/busy;
- Contacts hashing/discovery;
- camera/photo-library access;
- standard APNs;
- Sign in with Apple;
- Google OAuth;
- associated domains/App Clip;
- Notification Service Extension;
- Keychain auth and E2EE identities.

Explicitly **not** present/required:
- CoreNFC entitlement/API;
- PushKit/VoIP;
- CallKit/LiveKit mobile calls;
- Always-location request;
- automatic Apple Calendar event creation.

These negative findings are important: the native rewrite should not acquire extra entitlements merely because stale filenames or old documentation suggest them.
