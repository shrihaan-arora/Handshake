# HANDSHAKE — Security Findings & Architectural Decisions

**Branch:** `validation/v1-assurance`  
**Last Updated:** 2026-11-15  

---

## 1. Security Findings Log

| Finding ID | Severity | Category | Description | Status | Resolution |
| :--- | :---: | :---: | :--- | :---: | :--- |
| **SEC-01** | High | Hardware Crypto | Secure Enclave hardware strictly supports NIST P-256 (secp256r1) and lacks Curve25519 support. | Resolved | Standardized long-term identities on NIST P-256 ECDSA; ephemeral sessions on P-256 ECDH. |
| **SEC-02** | High | Protocol | SAS wire leakage risk if Short Authentication String is sent across the network. | Resolved | SAS is derived independently via HKDF(Transcript, SharedSecret) and visually confirmed. SAS is never transmitted over network. |
| **SEC-03** | High | DoS / Arithmetic | Integer overflow trap in `SequenceCounter` sliding window calculation near `UInt64.max`. | Resolved | Replaced addition with safe subtraction `highestSeen - seq < windowSize`. |
| **SEC-04** | High | DoS / Arithmetic | Integer underflow and `abs(Int64.min)` overflow trap in `HandshakeTime.isTimestampValid`. | Resolved | Added `subtractingReportingOverflow` and `guard timestampMilliseconds > 0`. |
| **SEC-05** | Medium | DoS / Parsing | Runtime trap when casting non-finite or extreme `Date` to `Int` in `PairingInvitation`. | Resolved | Added `.isFinite` and upper-bound checks before integer conversion. |
| **SEC-06** | Medium | AAD Ambiguity | Variable-length string concatenation in `associatedDataPayload` without length delimiters. | Resolved | Added 2-byte big-endian length prefixing (`UInt16`) to all variable-length string fields (`senderPublicKeyHex`, `recipientPublicKeyHex`). |
| **SEC-07** | Low | Logic Bypass | IEEE-754 NaN comparison in `CommandMessage.isExpired` returned false. | Resolved | Added `guard age.isFinite else { return true }`. |
| **SEC-08** | Low | State Machine | `SequenceCounter.nextOutgoing()` trapped on reaching `UInt64.max`. | Resolved | Saturated counter at `UInt64.max` to prevent crash and signal session re-negotiation. |
| **SEC-09** | High | DoS / State Poisoning | Sequence counter state desynchronization if unauthenticated or tampered packet mutates sequence window. | Resolved | Implemented two-phase sequence validation: pre-flight check freshness before crypto, commit to state only after digital signature and AEAD decryption pass. |
| **SEC-10** | Medium | Privacy / Battery | Persistent background Bluetooth scanning or advertising causes battery drain and beacon tracking. | Resolved | Restricted CoreBluetooth strictly to foreground active windows on both platforms with 4s bounded timeouts and explicit connection cancellation. |
| **SEC-11** | Critical | Lock Security | Starting macOS screen saver does not require password if system lock grace period > 0. | Resolved | `MacLockEngine` queries `/usr/sbin/sysadminctl -screenLock status`. Fails closed if not `.immediate`. Setup warning banner in `MacDashboardView`. |
| **SEC-12** | High | Race Condition | Fixed 200ms sleep delay risks dropped packet if Mac powers down network before client receives ACK. | Resolved | Designed two-stage handshake: Mac sends signed ACK -> iPhone confirms with signed `CommandReceipt` -> Mac sleeps upon receipt (2.0s bounded fallback). |
| **SEC-13** | Medium | Honesty / Disclosure | Early UI labels referenced "TLS 1.3" whereas transport uses Application-Level AEAD over Raw TCP. | Resolved | Updated `MacDashboardView.swift` and documentation to honestly disclose "Application-Level AEAD (AES-256-GCM + P-256 ECDSA) over TCP". |
| **SEC-14** | Medium | UI Security Honesty | Badges claimed "Hardware Rooted" on simulator targets where Secure Enclave is absent. | Resolved | `SecurityShieldBadge` and `SecurityAuditView` dynamically inspect `isHardwareBacked` from `CryptoIdentity`; display "Keychain-Pinned E2EE" on simulator. |
| **SEC-15** | High | Eavesdropping / Key Separation | Deriving symmetric AEAD session keys solely from recipient/sender public keys left payloads vulnerable to eavesdropping if public keys were observed on local Wi-Fi, and lacked directional separation. | Resolved | Derived 256-bit Pairwise Master Key (`preSharedKeyHex`) during mutual ECDH pairing stored in Keychain-backed `TrustRecord`. Expanded directional subkeys (`ClientToHost` vs `HostToClient`) via HKDF-SHA256 with domain separation strings. |
| **SEC-16** | High | Discovery Hijack / Ambiguity | Local Bonjour advertisement `_handshake._tcp` without identity metadata caused iPhone to pick `results.first`, potentially attempting connections with unintended or unpaired Macs on the same local Wi-Fi. | Resolved | Integrated Bonjour TXT records containing protocol version (`v=1`), host UUID (`id`), and short public key fingerprint (`pk`). `HandshakeClient.discoverMac` filters incoming advertisements to match the target paired Mac's identity. |
| **SEC-17** | High | Multi-Client Replay Collision | Single global `SequenceCounter` in `HandshakeServer` caused concurrent paired devices (e.g. multiple iPhones) to collide on sequence numbers and falsely reject legitimate commands as replays. | Resolved | Refactored `HandshakeServer` to maintain isolated per-peer sequence counter state dictionaries (`[String: SequenceCounter]`) keyed by sender public key hex, providing strict anti-replay tracking per paired peer. |

---

## 2. Core Architectural Invariants

1. **Zero External Dependencies:** 100% native Apple SDKs (`CryptoKit`, `Security`, `Network`, `CoreBluetooth`, `Foundation`, `SwiftUI`, `IOKit`).
2. **Hardware Identity Isolation:** Long-term private keys reside in Secure Enclave where supported; simulator uses clearly isolated software fallback.
3. **Fail-Closed Lock Enforcement:** Remote lock commands are rejected if macOS authentication grace period is not set to Immediate.
4. **No Persistent Background Process:** Strictly foreground lifecycle on iOS (0 background modes); companion window-bound lifecycle on macOS.
5. **Mutual Bilateral Authorization:** Pairing requires explicit confirmation on both devices.
6. **No Telemetry / No Cloud:** 100% local-first peer-to-peer transport over Wi-Fi/BLE. Zero external servers.
