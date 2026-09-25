# Click iOS — Round 5 handoff

This continues `Click iOS — Handoff Plan (round 4)`. Rows F50–F87 in `Docs/PARITY_LEDGER.md` record what round 4 finished, and `Docs/BACKEND_CONTRACT_MATRIX.md` has the routes. This file lists **only what is left**, in order, with the facts already researched, so the next agent doesn't have to repeat that work.

Source priority is unchanged: `CLICK_NATIVE_IOS_REBUILD_SPEC.md` > the prototype HTML "Interaction contracts" page > KMP (`../click`).

User decisions:
- The pixelated Click Drop preview is correct; keep it.
- Clicktivities is deprecated: audit it, don't surface it.
- Keep the code DRY, with no regressions.
- Backend (click-web) changes are allowed when additive and backward compatible with KMP.

## 0. Ground rules (verified this round)

Build and test:
- The iPhone 17 simulator (`264DEE86…`) **never starts tests**; it hangs after the build. Use **iPhone 18 Pro `72F1B726-931E-4450-9617-919CEE1EFABA`**.
- Test command:
  ```
  xcodegen generate
  xcodebuild test -scheme ClickTests -destination 'platform=iOS Simulator,id=72F1B726-931E-4450-9617-919CEE1EFABA' \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    -derivedDataPath /tmp/claude-501/click-dd -collect-test-diagnostics never
  ```
  Without `-collect-test-diagnostics never`, each run waits 10 extra minutes after the tests finish.
- Release build:
  ```
  xcodebuild build -scheme Click -configuration Release -destination 'generic/platform=iOS Simulator' <same signing flags>
  ```
- Baseline at handoff: **171 tests in 41 suites pass**. click-web jest suites `__tests__/app/api/{chat,safety,users}` pass.

Swift 6 pitfalls hit this round:
- **Static constants and helpers in `@MainActor` types that pure code or tests call must be `nonisolated`.** This includes `View` structs and `@MainActor` classes.
- **Don't pass `[String: Any]` or `UserDefaults` into actors.** Serialize to `Data` first (see `BeaconRepository.create(json:)`) or pass a suite name (see `TelemetryQueue(suiteName:)`).
- **MapKit/UIKit delegates on a `@MainActor` class:** use `@preconcurrency` conformance (see `PlaceSearchModel`).
- **iOS 26 APIs:** wrap them in `#if compiler(>=6.2)` + `#available` (see `GlassCircle.swift`).

Ledger:
- Append rows with the helper pattern: rows go before `## Phase 4 Direct Chat merge gate`.
- Mark device, staging and cross-client checks Pending.

click-web:
- Nothing is committed. `click-web` is on `main` with uncommitted changes, and so is `click-ios`. **Create a branch before committing.**
- Both round-4 migrations are **applied**: `20260924120000_users_bio.sql` and `20260924121000_message_tombstones.sql`.

## 1. Built in round 4 (for orientation)

| Area | Key files |
|---|---|
| Connectivity-aware offline notice, cancellation, retry, single-flight/proactive refresh | `Core/Network/NetworkMonitor.swift`, `DesignSystem/Components/OfflineNotice.swift`, `Core/Feed/ModuleState.swift`, `Core/API/ClickAPIClient.swift`, `Core/Auth/SessionController.swift` |
| Caches | `Core/Persistence/FreshnessCache.swift`, `Core/Identity/IdentityCache.swift`, beacon cache in `BeaconRepository` |
| Cold start | `OnboardingCoordinator.adoptCachedCompletion/isResolved`, `RootGateView` |
| Chat core | `ChatView` (scroll anchoring, jump-to-latest), `ChatComposerView` (morphing glass controls, hold-to-record, tray), `MessageBubbleView` (`SwipeReplyPhysics`, upload veil, tombstone), `ConversationModel` (`performSend`/`transmitPending`, staging), `Core/Chat/PendingSendStore.swift`, `Core/Chat/MediaValidator.swift` |
| Inbox actions | `Features/Clicks/ConversationActions.swift` (one implementation for inbox, chat header, profile, group, hub), `ConversationListModel` action methods |
| Nearby / map | `NearbySheet` (`liveHeight`, `settledDetent`), `MapFeatureModel.clusters`, person callout, friction and grass nudge |
| Post-connect | `Features/Connect/PostConnect{Model,View}.swift`, `ContextTagPicker.swift`, `Core/Connections/{ContextTagTaxonomy,EncounterContextRepository,EncounterSensorSampler}.swift` |
| Telemetry | `Core/Telemetry/*`, `Docs/TELEMETRY.md` |
| Compatibility | `ProximityCodec.randomToken` (no adjacent repeats or leading 0), `QRRedeemMessages`, `Core/Debug/ConnectionDebugLog.swift` (`-connection-log`), `Docs/IN_PERSON_TEST_MATRIX.md` (includes the KMP decoder bug write-up to file) |
| Profiles | `EncounterLabels` (KMP formats), `EncounterTagEditor`, bio and remove photo, `PublicProfileView` |
| Events | `Features/Events/BeaconForm.swift` (place search, rules, JPEG), `CreateBeaconSheet(editing:)`, `EventReminderScheduler`, `GuestListView` |
| Backend (click-web) | `GET /api/safety/block` (+ bearer-aware client for the whole route), `PATCH …/profile {bio}`, `DELETE /api/user/avatar`, message tombstones |

## 2. Remaining work, in order

### 2.1 §3.6 Message operations (spec §33–34)

Already done: tombstones (F87), Mark Unread (inbox and chat header via `DirectConversationActions`), edit (PATCH, own text), delete confirm-less.
- **Delete confirmation:** add "Delete for everyone?" before `onDelete` in `MessageBubbleView`'s context menu (currently immediate).

**Forward**
- Add a context-menu item that opens a picker of Clicks and groups. Reuse `ShareToChatSheet`'s list from `BeaconDetailView.swift`; it already lists conversations.
- Text: call `ChatRepository.sendMessage` per target. It re-encrypts per conversation.
- Media:
  - Get plaintext through `model.mediaURL(for:)` (a decrypted local file).
  - Build a `MediaDraft` and call `sendMedia` per target. **Never copy ciphertext across chats.**
  - Use a fresh `clientMessageID` per target.

**Save to Photos / Share**
- Images: add "Save to Photos" via `PHPhotoLibrary.requestAuthorization(for: .addOnly)`, then `UIImageWriteToSavedPhotosAlbum` or `PHAssetCreationRequest`. The `NSPhotoLibraryAddUsageDescription` string already exists.
- Files and voice notes: add a `ShareLink(item: localURL)`.

**Reactions: who reacted**
- `ReactionSummary` entries come from `raw.reactions` (emoji → entries with user ids).
- Add a long-press on a reaction chip that opens a sheet listing names via `env.identities.resolve(ids)`.

**Unread divider**
- On open, remember the ID of the first incoming message with `deliveryStatus != .read`. `loadMessages` marks messages read, so capture it before that.
- Insert a "New messages" row before it. Keep it until the chat closes.

**In-chat search**
- Search over `model.items` plaintext (it's already decrypted).
- To jump to results outside the loaded window, call `/api/chat/messages?chatId=&aroundMessageId=` (the server supports it: around-mode returns the target plus up to `limit` older and up to 40 newer, newest first).
- Add `ChatRepositoryProtocol.fetchMessages(around:)` and merge the rows with `mergeFetched`.
- Hub route: `/api/hub/messages` — check whether it supports `aroundMessageId` in click-web before relying on it.
- Global search (`GlobalSearchView`, `MessageHit`) should deep-link into this.

**Typing names in groups**
- `realtimeManager.onTypingChanged` gives user IDs. Map them through `IdentityCache` to "Lena is typing…" or "Lena and Sam are typing…".

**48-hour window**
- New connection that hasn't said hi (`ConnectionItem.sayHiDeadline`): show a warning strip plus icebreakers.
- Port the icebreakers and vibe check from KMP `viewmodel/ChatViewModelVibeIcebreakers.kt`. The prototype's Jordan chat shows the design.

### 2.2 §3.7 Click Drop camera (port KMP)

Sources:
- `ui/camera/DisposableCameraView.kt`, `DisposableCameraShared.kt` (UI)
- `ui/camera/DisposableRollFilters.kt` (the list)
- `iosApp/SharedNative/ClickDisposableRollFilter.m` (Core Image parameters)

Filters (exact values):
- Natural: none
- Warm: `CITemperatureAndTint` neutral 6500 → target 6200 K
- Cool: → 4200 K
- Vintage: `CISepiaTone` 0.82
- Dramatic: `CIColorControls` contrast 1.45
- Fade: brightness −0.35, saturation 0.72
- Noir: `CIPhotoEffectMono`
- Vibrant: saturation 1.65
- Golden: sepia 0.45 → saturation 1.18
- Moody: `CIVignette` intensity 0.85 / radius 1.35 → contrast 1.18

Previews are capped at 1280 px.

Build:
- AVCaptureSession with a full-screen UI: flash, flip, shutter animation, film counter, then preview, retake, send.
- Replace `CameraCapture` for `.clickDrop` in `ComposerAttachmentButton` (`ChatMediaViews.swift`).
- Metadata is already written by `ChatRepository.sendMedia`: `disposable_roll: true`, `collaboration_ttl` = now + 24 h. Add `encounter_id` when an encounter is active: `ProximityMatch.encounterID` is now parsed, so pass it through the post-connect "Say hi" route.
- **Keep the existing pixelated locked preview** (`ChatImageView.pixelated`).
- Live develop: when `revealAt` passes, re-render. Add a `TimelineView` or timer in `ChatImageView`, plus a local banner "Your Click Drop developed".
- Collaboration session (§44.1–44.2): `ProximityMatch.collaborationEndsAt` is parsed. Add a "Send a Click Drop" action in `PostConnectView` while it's in the future, and close the camera when it expires.

### 2.3 §3.8 Hub media

- Currently: `ConversationModel.supportsMedia` is false for hubs, and `ChatRepositoryError.mediaUnsupported` has "isn't available on iOS yet" copy. Remove both when done.
- Upload: `POST /api/hub/media` is **multipart** with fields:
  - `hub_id`
  - `object_path` = `{uid}/hub/{hubId}/<20-char random>.bin`
  - `file`
  - `mime_type`
  - `user_lat`, `user_long` (geofence)
  - optional v2: `e2ee_v2_envelope`, `media_ciphertext_sha256`, `epoch`, `sender_device_id`, `client_message_id`
- Limit: 25 MiB. Response: `201 {path, bucket:"hub-media", url, ttl_seconds:300}`.
- Read: `GET /api/hub/media?hub_id=&path=` returns a fresh URL.
- Encrypt with v2 `ClickCryptoV2.encryptMedia` using the hub epoch session (the same `resolveV2Session(scope: .hub(hubID))` used for hub text). Legacy `deriveKeysForHub` is read-only.
- Message metadata keys: `media_path`, `media_bucket:"hub-media"`, `is_encrypted_media`, `original_mime_type`, `crypto_version`, `media_chat_id`, `media_epoch`, `media_sender_device_id`, `media_client_message_id`, `media_ciphertext_sha256`, `media_authorization_envelope`.
- References: KMP `viewmodel/HubChatViewModel.kt:472` (images), `:586` (disposable), `:698` (`resolveHubMediaUrl`).
- `ClickAPIClient` has no multipart helper yet. Add one: build the body `Data` and pass it with a `Content-Type: multipart/form-data; boundary=…` header. `APIRequest.headers` override the JSON content type.
- Add E2EE vectors to `Docs/E2EE_COMPATIBILITY.md`.

### 2.4 §9 Remaining items

**Availability overlaps**
- RPC `get_availability_overlaps {p_peer_ids:[uuid]}` returns `[{peer_id, has_overlap}]`. Call it via the Supabase RPC path the same way `GroupRepository.rpcData` does.
- Home card: "N Clicks are also free tonight".

**Groups**
- Pre-check with `verified_clique_edges_exist {p_member_ids:[uuid]}` (deduplicated, sorted, ≥2) → Bool in `NewGroupSheet`; show ineligible people disabled with a reason.
- Realtime membership updates.
- Remove group avatar: needs a web route. Mirror `DELETE /api/user/avatar` for the group avatar route (find the group avatar route in click-web `app/api/groups/*`).

**Hubs:** owner edits category; add a hub info screen (members/occupants, category, geofence radius).

**Settings**
- Appearance: System / Light / Dark. `SettingsStore.darkModeEnabled` exists; add a tri-state.
- Web dashboard link.
- Delete account stays web-only; record it as a blocker.

**Push**
- Route tests per `type` in `ClickNotificationCoordinator.handleNotificationTap`.
- Notification Service v2 fallback text "Open Click to view it".

**Audits**
- Waitlist: keep `venue_id` QR parsing only.
- Clicktivities: audit only.

**Accessibility**
- Dynamic Type, VoiceOver and Reduce Motion pass on the new screens: `PostConnectView`, `StagedAttachmentTray`, `VoiceHoldStrip`, `NearbySheet`, `CreateBeaconSheet`, `GuestListView`, `BlockedUsersView`, `PublicProfileView`.

### 2.5 Smaller follow-ups found this round
- **Home:** entrance animations still replay on `opportunity?.id` changes, and section heights aren't reserved (item 9).
- **Noise capture:** no iOS opt-in UI (`SettingsStore.ambientNoiseOptIn` exists). Add a Privacy toggle plus 2 s AVAudioRecorder metering → `noise_level`/`exact_noise_level_db` (KMP thresholds: <35 very quiet, <55 quiet, <75 moderate, <90 loud, else very loud).
- **Elevation category:** not derived. KMP uses relative altitude (<−3 below ground, <8 ground, <35 elevated, else high rise).
- **Event reminders:** server `event_reminder` pushes may duplicate the local ones; a product decision is needed.
- **Screenshots:** capture with the `-preview-*` launch args on a **signed** build. That wasn't done this round.
- **KMP decoder bug:** file it from the write-up in `Docs/IN_PERSON_TEST_MATRIX.md`.

## 3. Definition of done per section
1. Full test suite green on iPhone 18 Pro.
2. Release build green.
3. Ledger and contract-matrix rows added.
4. Anything device-, staging- or cross-client-dependent is left as Pending. Never claim it.
