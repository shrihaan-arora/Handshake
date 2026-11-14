# HANDSHAKE — V1 Implementation Status

**Branch:** `marathon/handshake-v1`  
**Last Updated:** 2026-11-15  

---

## 1. Subsystem Implementation Status

| Component | Layer | Target Hardware / Platform | Implemented | Tested | Status |
| :--- | :--- | :--- | :---: | :---: | :---: |
| **Protocol Data Models** | Core | iOS 17+, macOS 14+ | Yes | Yes (51 tests) | Hardened |
| **Monotonic Replay Window** | Core | iOS 17+, macOS 14+ | Yes | Yes | Hardened |
| **Timing & Skew Engine** | Core | iOS 17+, macOS 14+ | Yes | Yes | Hardened |
| **Keychain Identity Engine** | Crypto | Secure Enclave (P-256) / Keychain | Yes | Yes (6 tests) | **Implemented (Milestone B)** |
| **Trust Store Subsystem** | Crypto | Persistent Keychain Device Registry | Yes | Yes | **Implemented (Milestone B)** |
| **Ephemeral ECDH & SAS** | Crypto | P-256 Key Agreement / HKDF-SHA256 | Yes | Yes | **Implemented (Milestone B)** |
| **QR Code Pairing Protocol** | Protocol | Camera (iOS) / CoreImage (macOS) | Yes | Yes (5 tests) | **Implemented (Milestone C)** |
| **Wi-Fi Transport (Bonjour)** | Network | `_handshake._tcp` (NWListener/NWConnection) | Yes | Yes | **Implemented (Milestone D)** |
| **AEAD Wire Framing** | Crypto | AES-256-GCM / HKDF-SHA256 / 4-byte framing | Yes | Yes (6 tests) | **Implemented (Milestone D)** |
| **Lock Mac Command Engine** | macOS System | macOS 14+ Apple Silicon | Yes | Yes (SystemEngineTests) | **Implemented (Milestone E)** |
| **Sleep Mac Command Engine** | macOS System | IOKit power management | Yes | Yes (SystemEngineTests) | **Implemented (Milestone F)** |
| **Bluetooth LE Transport** | Network | CoreBluetooth Central/Peripheral | Yes | Yes (BLETransportTests) | **Implemented (Milestone G)** |
| **iPhone Dashboard UI** | iOS App | iPhone 16e (A18), iOS 17+ | Yes | Yes | **Integrated** |
| **Mac Companion UI** | macOS App | MacBook Air (M4), macOS 14+ | Yes | Yes | **Integrated** |

---

## 2. Platform Permission & Entitlement Inventory

- **iOS (`Handshake-iOS`):**
  - Camera (`NSCameraUsageDescription`): Required for QR code scanning during pairing.
  - Local Network (`NSLocalNetworkUsageDescription`): Required for Bonjour discovery of `_handshake._tcp`.
  - Bonjour Services (`NSBonjourServices`): Registered `_handshake._tcp`.
  - App Sandbox / Security: Standard iOS application container.
- **macOS (`Handshake-macOS`):**
  - App Sandbox: `com.apple.security.app-sandbox` = YES.
  - Network Server: `com.apple.security.network.server` = YES (incoming local TCP connection).
  - Network Client: `com.apple.security.network.client` = YES.
  - Local Network Usage: Documented for peer command listening.
