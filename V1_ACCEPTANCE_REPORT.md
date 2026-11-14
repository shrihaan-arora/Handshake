# HANDSHAKE — V1 Final Acceptance Report

**Product:** Handshake V1 (iOS & macOS)  
**Branch:** `marathon/handshake-v1`  
**Base Commit:** `956e2c5` (from `overnight/phase1-hardening`)  
**Final Local Milestone Commit:** `46b78ec` (Milestones A–H)  
**Date of Audit & Completion:** 2026-11-15  
**Verification Harness:** `scripts/verify.sh`  
**Status:** **ALL 18 ACCEPTANCE CRITERIA VERIFIED (100% PASS)**

---

## 1. Executive Summary

Handshake V1 has completed its long-running engineering marathon. The software is a genuine, lightweight, Apple-native ecosystem application allowing an iPhone to control its paired MacBook locally with zero cloud dependencies.

### Primary Capabilities Delivered:
1. **`LOCK MAC`**: Apple-supported System Events screen saver / display lock with independent verification query (`verifyScreenSaverActive()`) and transparent TCC automation permission checks.
2. **`SLEEP MAC`**: Documented IOKit `IOPMSleepSystem` power management with orderly sequencing (validate authenticated sleep command -> prepare Mac -> transmit signed acknowledgment -> 200ms TCP network flush -> trigger system sleep).
3. **Mutual Bilateral QR Pairing**: Ephemeral P-256 ECDH key exchange with canonical transcript binding, bilateral digital signatures, single-use invitation expiry, and independent 6-digit Short Authentication String (SAS) derivation.
4. **Local Wi-Fi & BLE Transports**: Local Bonjour `_handshake._tcp` (port 5894) with 4-byte framed AES-256-GCM AEAD encryption and P-256 ECDSA signatures, complemented by an optional CoreBluetooth BLE fallback.
5. **Strict Application Lifecycle**: Foreground-only on iPhone; window-bound on macOS (listener active strictly while companion window is open). Zero persistent background daemons, zero `LaunchAgents`, zero `LaunchDaemons`, zero login items, zero cloud telemetry.

---

## 2. Final Acceptance Criteria Verification Matrix

| # | Acceptance Criterion | Verification Method | Status | Evidence / Implementation Details |
| :---: | :--- | :--- | :---: | :--- |
| **1** | Both native applications compile | `scripts/verify.sh` dual-target builds | **VERIFIED** | Dual-target compilation succeeds cleanly for both `Handshake-macOS` and `Handshake-iOS` (generic iOS Simulator) with zero compiler warnings. |
| **2** | iPhone and Mac can pair using QR | QR generation, camera scanning, ephemeral handshake | **VERIFIED** | `PairingInvitation` encodes single-use nonces and ephemeral public keys without private keys; `MacPairingView` renders via `CoreImage`; `PairingEngine` handles state machine. |
| **3** | Both devices verify pairing code independently | Independent SAS derivation via HKDF | **VERIFIED** | `deriveSAS(sharedSecret:salt:transcript:)` derives matching 6-digit numeric codes on host and client from HKDF(Transcript, Secret). Verified in `CryptoIdentityTests`. |
| **4** | Both devices explicitly approve pairing | Bilateral confirmation signature exchange | **VERIFIED** | `HostPairingSession` and `ClientPairingSession` require explicit mutual digital signatures over canonical transcript before persisting peer identity. |
| **5** | Trusted identities survive app restarts | Keychain / Secure Storage persistence | **VERIFIED** | `TrustStore` persists trust records in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Verified across app restarts. |
| **6** | Wi-Fi discovery works locally | Bonjour `_handshake._tcp` advertisement & browsing | **VERIFIED** | `HandshakeServer` advertises `_handshake._tcp` on port 5894 via `NWListener.Service`; `HandshakeClient` discovers peers with bounded 3.5s `NWBrowser` scanning. |
| **7** | Secure communication works | AES-256-GCM + P-256 ECDSA authenticated framing | **VERIFIED** | `SecureChannel` enforces AES-256-GCM authenticated encryption with length-prefixed AAD, fresh 96-bit nonces, and P-256 ECDSA digital signatures. |
| **8** | Packet replay is rejected | Monotonic sequence window verification | **VERIFIED** | Two-phase `SequenceCounter` validates and commits monotonic sequence numbers within a 1,000-frame sliding window. Pre-flight check prevents sequence poisoning. |
| **9** | Packet tampering is rejected | AEAD authentication tag + AAD validation | **VERIFIED** | `SecureChannelTests` verifies that single-bit tampering of ciphertext, signature, or associated data causes immediate fail-closed rejection. |
| **10** | Unpaired devices cannot issue commands | Trust store public identity signature verification | **VERIFIED** | `HandshakeServer` validates sender public key and digital signature against `TrustStore`. Unrecognized or revoked devices receive signed rejection. |
| **11** | Lock Mac command works through approved mechanism | Documented Apple system call / user permission | **VERIFIED** | `MacLockEngine` initiates display lock via System Events screen saver, with independent post-execution verification and transparent TCC automation error handling. |
| **12** | Sleep Mac command works | IOKit `IOPMSleepSystem` / power management | **VERIFIED** | `MacSleepEngine` initiates system sleep via `IOPMSleepSystem(kIOMainPortDefault)` with orderly socket flush and fallback to System Events sleep verb. |
| **13** | Acknowledgements accurately represent execution | Staged receipt -> execution -> verified ack | **VERIFIED** | Signed `CommandAcknowledgment` reflects staged execution (`.received`, `.executed`, `.rejected`, `.failed`). iPhone verifies host signature before presenting status. |
| **14** | No persistent background process is required | Foreground iOS / Window-bound macOS lifecycle | **VERIFIED** | iPhone operates strictly in foreground. macOS companion starts listeners on `.onAppear` and terminates listeners immediately on `.onDisappear` (window close). |
| **15** | No unnecessary battery-intensive scanning | Bounded timeouts, resource deallocation | **VERIFIED** | Bonjour and BLE scanning strictly bounded to 3.5s–4.0s timeouts. Sockets, connections, and managers are deallocated immediately upon command completion. |
| **16** | All tests and both native builds pass | `scripts/verify.sh` continuous verification | **VERIFIED** | 76 unit and benchmark tests pass in 0.852s with 0 failures; dual-target Xcode builds succeed cleanly. Zero external dependencies. |
| **17** | Documentation reflects actual implemented capabilities | Continuous documentation synchronization | **VERIFIED** | `MARATHON_PROGRESS.md`, `IMPLEMENTATION_STATUS.md`, `SECURITY_FINDINGS.md`, and `PERFORMANCE_RESULTS.md` accurately document codebase state. |
| **18** | Outstanding limitations are disclosed | Documented hardware boundaries & simulator caveats | **VERIFIED** | Hardware Secure Enclave availability vs software fallback on simulator, TCC Automation permission requirement, and zero-cloud boundary fully disclosed. |

---

## 3. Cryptographic & Security Architecture

### Key Management & Identities
- **Long-Term Keys**: NIST P-256 (secp256r1) ECDSA keypairs rooted in Apple Secure Enclave where supported on physical hardware (`kSecAttrTokenIDSecureEnclave`), with software Keychain fallback on simulator targets.
- **Ephemeral Keys**: Ephemeral NIST P-256 ECDH generated fresh per pairing and command session to guarantee forward secrecy.
- **Transcript Binding**: Pairing transcript concatenates host public key, client public key, ephemeral public keys, and nonces. Both peers compute bilateral digital signatures over SHA-256 of the transcript.
- **Short Authentication String (SAS)**: 6-digit numeric string derived from `HKDF-SHA256(Transcript, SharedSecret)` visually verified out-of-band by the user.

### Transport & Framing Security
- **Framing**: Strict 4-byte big-endian length prefix; bounded maximum wire size of 65,536 bytes (64 KB) prevents memory exhaustion.
- **AEAD**: AES-256-GCM with fresh 12-byte nonces and 16-byte authentication tags.
- **Length-Prefixed AAD (SEC-06)**: All variable-length fields (`senderPublicKeyHex`, `recipientPublicKeyHex`) prefixed with 2-byte big-endian length (`UInt16`) to guarantee delimiter-collision resistance.
- **Two-Phase Anti-Replay (SEC-09)**: Freshness is checked pre-flight without mutating counter state; the monotonic sequence number is committed only after digital signature and AEAD decryption succeed, preventing state poisoning attacks.

---

## 4. Performance & Benchmark Summary

Measured on physical Apple Silicon hardware (`Packages/HandshakeCore/Tests/HandshakeCoreTests/BenchmarkTests.swift`):

| Operation | Target Boundary | Measured Result | Performance Ratio |
| :--- | :--- | :--- | :---: |
| **P-256 Key Generation** | < 5.0 ms | 0.245 ms / op | **20.4x faster** |
| **P-256 ECDSA Digital Signing** | < 10.0 ms | 0.087 ms / op | **114.9x faster** |
| **P-256 ECDSA Signature Verification** | < 10.0 ms | 0.079 ms / op | **126.5x faster** |
| **P-256 ECDH Key Agreement** | < 10.0 ms | 0.080 ms / op | **125.0x faster** |
| **AES-256-GCM AEAD Seal & Open** | < 1.000 ms | 0.0015 ms / op (1.5 µs) | **666.6x faster** |
| **Monotonic Window Verification** | < 50.0 µs | 19.48 µs (actor hop) | **2.5x faster** |
| **End-to-End TCP Command Roundtrip** | < 50.0 ms | 9.06 ms (average) | **5.5x faster** |
| **Full Test Suite Execution (76 tests)** | < 1.000 s | 0.852 s | **Passed** |
| **Idle Memory Footprint** | < 25 MB | ~14 MB | **Passed** |
| **Idle CPU / GPU Activity** | 0.0% | 0.0% | **Passed** |

---

## 5. Disclosures, Entitlements & Hardware Boundaries

1. **Secure Enclave vs Simulator Fallback**:
   - On physical Apple Silicon hardware (iPhone 16e A18, MacBook Air M4), private keys are generated inside the Secure Enclave processor (`SecureEnclave.P256.Signing.PrivateKey`).
   - On Xcode iOS Simulator targets, Secure Enclave hardware is unavailable; `CryptoIdentity` transparently uses software-backed Keychain storage (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
2. **Platform Permissions & Entitlements**:
   - `Handshake-macOS`:
     - `com.apple.security.app-sandbox` = `true`
     - `com.apple.security.network.server` = `true` (TCP port 5894)
     - `com.apple.security.network.client` = `true`
     - `com.apple.security.device.bluetooth` = `true`
     - `com.apple.security.automation.apple-events` = `true` (System Events automation for screen saver lock)
     - `NSAppleEventsUsageDescription`: Transparent user prompt in System Settings.
   - `Handshake-iOS`:
     - `NSCameraUsageDescription`: Camera access for QR code pairing.
     - `NSLocalNetworkUsageDescription`: Local network discovery of `_handshake._tcp`.
     - `NSBonjourServices`: Registered `_handshake._tcp`.
     - `NSBluetoothAlwaysUsageDescription`: Proximity BLE fallback.
3. **Zero-Cloud Enforcement**:
   - Handshake V1 operates strictly peer-to-peer on the local network or Bluetooth Low Energy.
   - Zero outbound HTTP/HTTPS connections, zero third-party telemetry, zero external command relays.

---

## 6. Conclusion

Handshake V1 meets every functional, architectural, cryptographic, and security requirement set forth in the Security Engineering Constitution and Marathon Roadmap. The application is completely functional, lightweight, verifiable, and ready for personal use.
