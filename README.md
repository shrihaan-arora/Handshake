# Handshake

**Handshake** is a security-focused native Apple ecosystem application allowing an iPhone to control its paired MacBook over direct local transport (Wi-Fi and Bluetooth Low Energy) with zero cloud servers.

Designed to feel like a first-party Apple application: minimalist, subtle, clean, and polished.

---

## Capabilities (V1 Roadmap)

- **Lock Mac Screen:** Immediately locks the paired MacBook display.
- **Put Mac to Sleep:** Places the host Mac into low-power system sleep.
- **Paired Device Status:** Real-time visibility into connection and power state.
- **Secure QR Pairing:** Out-of-band ephemeral key agreement with 6-digit SAS verification.
- **Zero Cloud Footprint:** Direct local peer-to-peer transport only. No telemetry or command-routing servers.

---

## Project Structure

```
Handshake/
├── Handshake.xcodeproj/          # Unified Xcode project (iOS & macOS targets)
├── Applications/
│   ├── Handshake-iOS/            # Native iPhone Application
│   │   ├── App/                  # SwiftUI App entry point
│   │   ├── Features/             # Dashboard, Pairing, Security Audit
│   │   ├── DesignSystem/         # Native Apple materials, pills, cards, theme
│   │   └── Resources/            # Info.plist
│   └── Handshake-macOS/          # Native macOS Host & Menu Bar Companion
│       ├── App/                  # SwiftUI App entry point & MenuBarExtra
│       ├── Features/             # Dashboard, MenuBar, QR Pairing, Trust Management
│       ├── DesignSystem/         # macOS design tokens & cards
│       └── Resources/            # Info.plist & Entitlements
├── Packages/
│   └── HandshakeCore/            # Local Swift Package (Shared Models & Protocol)
│       ├── Sources/HandshakeCore/
│       └── Tests/HandshakeCoreTests/
└── Documentation/
    ├── ARCHITECTURE.md           # System design & component boundaries
    ├── THREAT_MODEL.md           # STRIDE analysis & attacker models
    ├── SECURITY.md               # Cryptographic primitives & pairing protocol
    └── DEPENDENCIES.md           # Zero third-party dependency inventory
```

---

## Security Constitution

1. **Native Apple Cryptography:** Apple `CryptoKit` and `Security.framework` exclusively.
2. **Zero Third-Party Dependencies:** 100% native Apple SDKs (`CryptoKit`, `Network`, `CoreBluetooth`, `OSLog`).
3. **Replay Protection:** Monotonic sequence counters and strict 30-second timestamp validity windows.
4. **Hardware-Pinned Trust:** Device identity keys generated and preserved in Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
5. **Fail-Closed Architecture:** Unauthenticated or out-of-order packets are dropped instantly.

---

## Building & Testing

### Test HandshakeCore (Shared Package)
```bash
cd Packages/HandshakeCore
swift test
```

### Build macOS Host Companion
```bash
xcodebuild -project Handshake.xcodeproj -scheme Handshake-macOS build
```

### Build iOS Client Application
```bash
xcodebuild -project Handshake.xcodeproj -scheme Handshake-iOS -destination 'generic/platform=iOS Simulator' build
```

---

## Status

- **Phase 1: Foundation, Design System & Native Applications** — Completed
- **Phase 2: Cryptographic Engine & Mutual P-256 Pairing** — Completed
- **Phase 3: Secure Local Network & Authenticated System Actions (Lock & Sleep)** — Completed
- **Phase 4: SQLite Audit Database, Command History & Multi-Stage Pairing Diagnostics** — Completed
- **Phase 5: Visual Identity (AppIcon Assets), Root-Layer Camera Preview & Reliability Telemetry** — Completed
- **Automated Verification:** 161 unit, integration, and adversarial tests passing with 0 failures.
