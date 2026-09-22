# Parity Ledger

Tracks implementation, testing, and parity status of every reachable Click flow.

| ID | Flow | Backend Route | Native Entry | States Implemented | Automated | Device-Tested | Classification | Notes |
|---|---|---|---|---|---|---|---|---|
| F01 | Legacy Session Migration | N/A (Keychain) | `LegacyKMPStateMigrator` | Success, missing, invalid | Yes (Unit) | Pending | P0 COMPATIBILITY | Migrates `com.click.auth/session_v2` |
| F02 | Settings Preference Migration | N/A (UserDefaults) | `SettingsStore` | Success, defaults | Yes (Unit) | Pending | P0 COMPATIBILITY | Reads suite `click_auth_prefs` |
| F03 | Root Gate & App Launch | N/A | `RootGateView` | Restoring, Auth, Gate, Main | Yes (Unit) | Pending | P0 PARITY | Prevents login/onboarding flashes |
| F04 | Typed Routing & Deep Links | N/A | `AppRouter` | Path stack, pending intent | Yes (Unit) | Pending | P0 PARITY | Parses `click://` & universal links |
| F05 | API Client Foundation | `/api/*` | `ClickAPIClient` | Auth, Retry, Errors | Yes (Unit) | Pending | P0 PARITY | Foundation URLSession client |
| F06 | App Clip Shell | `/c/{uuid}` | `ClickClip` | Invocation, minimal UI | Pending | Pending | P0 COMPATIBILITY | Bundle `...click.Clip` |
| F07 | Notification Service Shell | APNs payload | `NotificationService` | Payload inspect, fallback | Pending | Pending | P0 COMPATIBILITY | Bundle `...click.NotificationService` |
