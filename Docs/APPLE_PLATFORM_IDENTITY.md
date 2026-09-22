# Apple Platform Identity

This document preserves the authoritative Apple developer and provisioning identity for `click-ios`.

| Item | Value |
|---|---|
| App Store Connect Name | Click Platforms / Click |
| Apple Developer Team ID | `W4C3V9Z2N4` |
| Main App Bundle ID | `compose.project.click.click` |
| App Clip Bundle ID | `compose.project.click.click.Clip` |
| Notification Service Bundle ID | `compose.project.click.click.NotificationService` |
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
