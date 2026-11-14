# HANDSHAKE — Software Architecture Specification

**Product:** Handshake  
**Platforms:** iOS 17+ and macOS 14+  
**Language:** Swift 6  
**UI Framework:** SwiftUI  
**Architecture:** Modular, Local-First, Zero-Trust Peer Architecture  
**Distribution:** Personal Use  

---

## 1. Architectural Principles

Handshake is built to look and feel like a first-party Apple application while enforcing rigorous cryptographic security:

1. **Strict Modularity:** All shared models, protocol envelopes, and security primitives live in `HandshakeCore`, an independent, testable local Swift package.
2. **Platform Native:** Pure SwiftUI interfaces tailored to platform idioms (touch targets and sheets on iOS; split views, tables, and MenuBarExtra on macOS).
3. **Local-First & Serverless:** Zero cloud server dependency in V1. Communication occurs strictly over direct local Wi-Fi and Bluetooth Low Energy.
4. **Decoupled Transports:** The command dispatch and application logic are completely decoupled from the underlying transport mechanism (Wi-Fi TLS or BLE).

---

## 2. Workspace & Target Structure

```
Handshake/
├── Handshake.xcodeproj/              # Unified Xcode project
├── Applications/
│   ├── Handshake-iOS/                # iOS Target (com.shrihaan.handshake.ios)
│   │   ├── App/                      # @main entry point & scene lifecycle
│   │   ├── Features/                 # Dashboard, Pairing Scanner, Security Audit
│   │   ├── DesignSystem/             # Apple-native cards, pills, buttons, themes
│   │   └── Resources/                # Info.plist, assets
│   └── Handshake-macOS/              # macOS Target (com.shrihaan.handshake.mac)
│       ├── App/                      # @main entry point & MenuBarExtra
│       ├── Features/                 # Dashboard, MenuBar, Pairing QR, Trust Management
│       ├── DesignSystem/             # macOS tokens, cards, materials
│       └── Resources/                # Info.plist, Entitlements
├── Packages/
│   └── HandshakeCore/                # Local Swift Package (iOS 17+ / macOS 14+)
│       ├── Sources/HandshakeCore/
│       │   ├── Models/               # DeviceIdentity, ConnectionState, TrustRecord
│       │   ├── Protocol/             # CommandType, CommandEnvelope, PairingMessage
│       │   └── Utilities/            # HandshakeTime, SequenceCounter
│       └── Tests/HandshakeCoreTests/ # XCTest suite (anti-replay, protocol, framing)
├── Documentation/                    # Architecture, Threat Model, Security, Dependencies
└── README.md
```

---

## 3. Layered System Architecture

```
+-------------------------------------------------------------------------+
| PRESENTATION LAYER (SwiftUI)                                            |
| iOS: iPhoneDashboardView, PairingScannerView, SecurityAuditView         |
| macOS: MacDashboardView, MenuBarView, MacPairingView, TrustManagement   |
+------------------------------------+------------------------------------+
                                     |
+------------------------------------+------------------------------------+
| BUSINESS LOGIC & VIEWMODELS        |
| DashboardViewModel (iOS)           | MacDashboardViewModel (macOS)      |
+------------------------------------+------------------------------------+
                                     |
+------------------------------------+------------------------------------+
| CORE DOMAIN & PROTOCOL (HandshakeCore)                                  |
| DeviceIdentity, TrustRecord, CommandEnvelope, SequenceCounter           |
+------------------------------------+------------------------------------+
                                     |
+------------------------------------+------------------------------------+
| INFRASTRUCTURE & APPLE FRAMEWORKS                                      |
| CryptoKit, Security.framework, Network.framework, CoreBluetooth, OSLog  |
+-------------------------------------------------------------------------+
```

---

## 4. Phase Roadmap

- **Phase 1: Foundation, Design System & Native Applications** *(Completed)*
  - Shared `HandshakeCore` package with clean models and anti-replay utilities.
  - Native iPhone Dashboard and macOS Companion with Menu-bar support.
  - Apple-native design system with light/dark mode support.
  - Zero-dependency supply chain inventory and threat model documentation.
- **Phase 2: Cryptographic Engine & Secure Out-of-Band Pairing** *(Next Milestone)*
  - NIST P-256 Secure Enclave & Keychain hardware identity management.
  - Ephemeral P-256 ECDH key agreement with transcript hashing.
  - Out-of-band 6-digit SAS verification (local derivation only; zero wire leakage).
  - Single-use pairing invitation consumption state machine.
  - Wire-level AES-256-GCM AEAD encryption over command envelopes.
- **Phase 3: Local Network Transport**
  - Bonjour discovery and mutual TLS 1.3 over `Network.framework`.
  - CoreBluetooth peripheral advertising and central discovery.
- **Phase 4: Remote Command Dispatch & macOS System Integration**
  - Screen locking and sleep triggering via native macOS APIs.
  - Battery/power status telemetry queries.
- **Phase 5: Refinement, Hardening & Security Audit**
  - End-to-end pen-testing against spoofing, packet modification, and replay attacks.

