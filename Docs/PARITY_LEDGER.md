# Parity Ledger

Tracks implementation, testing, and parity status of every reachable Click flow.

| ID | Flow | Backend Route | Native Entry | States Implemented | Automated | Device-Tested | Classification | Notes |
|---|---|---|---|---|---|---|---|---|
| F01 | Legacy Session & State Migration | N/A (Keychain & UserDefaults) | `LegacyKMPStateMigrator` | Success, missing, invalid, purged | Yes (Unit) | Verified | P0 COMPATIBILITY | Migrates `com.click.auth/session_v2`, extracts sub from JWT, purges retired keys |
| F02 | Settings Preference Migration | N/A (UserDefaults) | `SettingsStore` | Success, defaults | Yes (Unit) | Verified | P0 COMPATIBILITY | Reads/writes suite `click_auth_prefs` |
| F03 | Root Gate & App Launch | N/A | `RootGateView` | Restoring, Auth, Gate, Onboarding, Main | Yes (Unit) | Verified | P0 PARITY | Triple-gate hierarchy: session restore -> profile basics -> onboarding -> main tabs |
| F04 | Typed Routing & Deep Links | N/A | `AppRouter` | Path stack, pending intent, connection invocation | Yes (Unit) | Verified | P0 PARITY | Parses `click://` & universal links; routes `/c/*` to `addClick` with full invocation query parameters |
| F05 | API Client Foundation | `/api/*` | `ClickAPIClient` | Auth, Single-flight 401 refresh, Single retry, Errors | Yes (Unit) | Verified | P0 PARITY | URLSession client with automatic bearer token injection and 401 refresh |
| F06 | App Clip Shell | `/c/{uuid}` | `ClickClip` | Invocation, minimal UI | Pending | Pending | P0 COMPATIBILITY | Target: `...click.Clip` |
| F07 | Notification Service Shell | APNs payload | `NotificationService` | Payload inspect, fallback | Pending | Pending | P0 COMPATIBILITY | Target: `...click.NotificationService` |
| F08 | Supabase Auth Service | Supabase Auth (`/auth/v1/*`) | `SupabaseAuthService` | Email/Password, Sign In with Apple, Google OAuth, Refresh | Yes (Unit) | Verified | P0 PARITY | Typed SignUpResult (`authenticated` vs `verificationRequired`), SHA-256 nonces, token exchange |
| F09 | Session Controller & Restore Policy | Supabase Auth & Keychain | `SessionController` | Restore, Single-flight refresh, Offline identity, SignOut | Yes (Unit) | Verified | P0 PARITY | Hard 400/401 eviction, network timeout preservation, profile basics gate derivation |
| F10 | Profile Basics Gate & Sync | `PATCH /api/users/{userId}/profile` | `ProfileBasicsGateView` | Form, 13+ age validation, Remote sync | Yes (Unit) | Verified | P0 PARITY | Requires first/last name and valid birthday; persists directly to backend profile endpoint |
| F11 | Design System Brand Alignment | N/A | `Typography.swift`, `Colors.swift` | Manrope hierarchy, Click palette | Yes (Unit) | Verified | P1 DESIGN | `labelSmall` at 14pt SemiBold, `captionSmall` 12pt, `microcopy` 11pt, registered Manrope fonts |
| F12 | Permission Coordinator | CoreLocation, AVFoundation, Contacts | `PermissionCoordinator` | Non-eager status, Explicit gesture request, Settings deep link | Yes (Unit) | Verified | P0 PARITY | Contextual permission prompting, prevents eager launch prompt storms |
| F13 | Native Camera & Avatar Upload | `POST /api/user/avatar` | `AvatarService`, `NativeCameraPicker` | Native capture, Downsampling, JPEG <= 2 MB | Yes (Unit) | Verified | P0 PARITY | UIImagePickerController native wrapper, orientation correction, <= 2 MB byte guard |
| F14 | Privacy Contact Discovery | `POST /api/contacts/discover`, `POST /api/connections/prior/request` | `ContactDiscoveryService`, `PriorConnectionsView` | On-device E.164 normalization, SHA-256 hashing | Yes (Unit) | Verified | P0 PARITY | Zero plaintext contact uploads; hashes matched and prior connection requests triggered |
| F15 | Onboarding Flow & Server Reconciliation | `GET/PATCH /api/users/{userId}/profile` | `OnboardingRepository`, `OnboardingCoordinator` | 21 Interests, 24 Personality traits, Avatar, Prior Connections | Yes (Unit) | Verified | P0 PARITY | Remote server truth reconciles step progress; never marks steps complete before durable sync |

