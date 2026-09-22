# Click iOS

The official native iOS client for Click Platforms, built with Swift 6 and SwiftUI.

## Overview

This repository replaces the previous Kotlin Multiplatform (KMP) iOS implementation with a high-performance, native client designed for iOS 18.2+. It preserves:
- The existing Click App Store Connect product (`compose.project.click.click`) and Team ID (`W4C3V9Z2N4`).
- Existing user sessions via Keychain migration (`com.click.auth/session_v2`).
- Existing user preferences via `click_auth_prefs`.
- End-to-end encryption compatibility (E2EE v1 historical read, E2EE v2 direct, group, and hub).
- Associated domains, App Clip (`compose.project.click.click.Clip`), and Notification Service Extension.

## Getting Started

### Prerequisites
- macOS Sonoma or later
- Xcode 16.0+ (iOS 18.2 SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Generating the Xcode Project
```bash
xcodegen generate
open Click.xcodeproj
```

### Running Tests
```bash
xcodebuild test -project Click.xcodeproj -scheme ClickTests -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

### Architecture
- **Language**: Swift 6
- **UI Framework**: SwiftUI + native UIKit integrations where appropriate
- **Concurrency**: Structured Concurrency (`async`/`await`, `actor`)
- **State**: `@Observable` (Observation framework)
- **Networking**: URLSession-based typed client (`ClickAPIClient`) + isolated Supabase adapter
- **Security**: Keychain Services with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`

See `CLICK_NATIVE_IOS_REBUILD_SPEC.md` and `AI.md` for full design and architecture documentation.
