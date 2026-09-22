# Click iOS — AI & Contributor Context (Native Rebuild)

This repository (`click-ios`) is the clean native Swift / SwiftUI implementation replacing the legacy Kotlin Multiplatform iOS client while strictly preserving Click backend interoperability, user sessions, App Store identity, and product semantics.

---

## 1. Architectural Principles

- **Framework:** Swift 6, SwiftUI-first, UIKit only where SwiftUI lacks native parity (e.g. specialized collection view pinning or system integrations).
- **State Management:** `@Observable` (`Observation` framework) with `@MainActor` isolation for view models. Long-lived services isolated as Swift `actor`s.
- **Dependencies:** Lightweight, zero external UI/navigation frameworks. URLSession for HTTP, isolated Supabase client adapter, Apple native frameworks (CryptoKit, CoreBluetooth, AVFoundation, CoreLocation).
- **No Speculative Abstraction:** No `BaseViewModel`, no `BaseRepository`, no generic service locators. Keep code direct, typed, and maintainable.

---

## 2. Hard Platform & Feature Boundaries

- **Calls are REMOVED:** Do NOT add VoIP, CallKit, PushKit, LiveKit, call notifications, or call overlays.
- **Tap to Connect is NOT NFC:** Proximity handshake uses CoreBluetooth + ~18.5 kHz ultrasonic audio + progressive CoreLocation GPS. Do NOT add `CoreNFC` or NFC entitlements.
- **Home is Linear-Only:** The photo-pile layout mode is deprecated and removed. Home is a clean, linear social feed.
- **Identity Preservation:**
  - Team ID: `W4C3V9Z2N4`
  - Bundle ID: `compose.project.click.click`
  - App Clip: `compose.project.click.click.Clip`
  - Notification Service: `compose.project.click.click.NotificationService`
  - Minimum iOS: `18.2`
- **Session Migration:**
  - Keychain service: `com.click.auth`, account: `session_v2`
  - UserDefaults suite: `click_auth_prefs`
  - E2EE Keychain: service `com.click.e2ee.v2`, account `x25519_identity_private_key`

---

## 3. Project Configuration & Build Commands

Project files are generated via **XcodeGen**:
```bash
# Generate Xcode project
xcodegen generate

# Run tests
xcodebuild test -project Click.xcodeproj -scheme ClickTests -destination 'platform=iOS Simulator,name=iPhone 16 Pro'

# Build application
xcodebuild build -project Click.xcodeproj -scheme Click -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

---

## 4. Documentation References

- `CLICK_NATIVE_IOS_REBUILD_SPEC.md` — Authoritative specification for all flows and parity ledger.
- `Docs/BACKEND_CONTRACT_MATRIX.md` — API endpoints, auth requirements, DTOs, and error codes.
- `Docs/PARITY_LEDGER.md` — Tracking matrix for migration and feature parity.
- `Docs/E2EE_COMPATIBILITY.md` — E2EE v1/v2 cryptographic protocols, wire formats, and test vectors.
- `Docs/APPLE_PLATFORM_IDENTITY.md` — Bundle IDs, entitlements, capabilities, and App Store metadata.
