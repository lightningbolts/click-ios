# Apple Platform Identity

This document preserves the authoritative Apple developer and provisioning identity for `click-ios`.

| Item | Value |
|---|---|
| App Store Connect Name | Click Platforms / Click |
| Apple Developer Team ID | `W4C3V9Z2N4` |
| Main App Bundle ID | `compose.project.click.click` |
| App Clip Bundle ID | `compose.project.click.click.Clip` |
| Notification Service Bundle ID | `compose.project.click.click.NotificationService` |
| Widgets Extension Bundle ID | `compose.project.click.click.Widgets` (event Live Activity; `NSSupportsLiveActivities` on the app) |
| URL Schemes | `click`, `com.googleusercontent.apps.530817233802-crnehf5a9duauov4vos4lgsijkgingdj` |
| App Store Listing ID | `6757996346` |
| Associated Domains | `applinks:joinclick.co`, `applinks:www.joinclick.co`, `applinks:click-us.vercel.app` |
| App Clip Associated Domains | `appclips:joinclick.co`, `appclips:www.joinclick.co`, `appclips:click-us.vercel.app` |
| Minimum iOS Deployment Target | `18.2` |
| Non-Exempt Encryption | `ITSAppUsesNonExemptEncryption = false` |

## Keychain Coordinates

### Auth Session v2
- **Service**: `com.click.auth`
- **Account**: `session_v2`
- **Accessibility**: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`

### E2EE v2 Device Identity
- **Service**: `com.click.e2ee.v2`
- **Account**: `x25519_identity_private_key`
- **Format**: 32 raw private-key bytes
- **Accessibility**: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`

## Click Pass and Apple Wallet

- The app adds Click Passes with `PKAddPassesViewController` / `AddPassToWalletButton`: no entitlement needed.
- Signing is server-side (click-web `WALLET_PASS_TYPE_ID`, `WALLET_PASS_CERT`, `WALLET_PASS_KEY`, `WALLET_WWDR_CERT`). Create the Pass Type ID (e.g. `pass.co.joinclick.event`) under team `W4C3V9Z2N4`. Until it's configured the server reports `wallet_available: false` and the button is hidden.
- Optional: adding the Pass Type ID to the app's `com.apple.developer.pass-type-identifiers` entitlement lets the pass screen read "View in Wallet" for passes already added (without it, Wallet itself says the pass is already there).
- Calendar: "Add to Calendar" lets the user choose: Apple Calendar opens the system add-event sheet (its own calendar picker, covering iCloud and any Google/Exchange/Outlook account on the device; no calendar permission needed), and Google Calendar / Outlook open their prefilled add-event pages.
