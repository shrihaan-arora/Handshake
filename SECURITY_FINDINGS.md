# HANDSHAKE — Security Findings & Architectural Decisions

**Branch:** `marathon/handshake-v1`  
**Last Updated:** 2026-11-15  

---

## 1. Security Findings Log

| Finding ID | Severity | Category | Description | Status | Resolution |
| :--- | :---: | :---: | :--- | :---: | :--- |
| **SEC-01** | High | Hardware Crypto | Secure Enclave hardware strictly supports NIST P-256 (secp256r1) and lacks Curve25519 support. | Resolved | Standardized long-term identities on NIST P-256 ECDSA; ephemeral sessions on P-256 ECDH. |
| **SEC-02** | High | Protocol | SAS wire leakage risk if Short Authentication String is sent across the network. | Resolved | SAS is derived independently via HKDF(Transcript, SharedSecret) and visually confirmed. |
| **SEC-03** | High | DoS / Arithmetic | Integer overflow trap in `SequenceCounter` sliding window calculation near `UInt64.max`. | Resolved | Replaced addition with safe subtraction `highestSeen - seq < windowSize`. |
| **SEC-04** | High | DoS / Arithmetic | Integer underflow and `abs(Int64.min)` overflow trap in `HandshakeTime.isTimestampValid`. | Resolved | Added `subtractingReportingOverflow` and `guard timestampMilliseconds > 0`. |
| **SEC-05** | Medium | DoS / Parsing | Runtime trap when casting non-finite or extreme `Date` to `Int` in `PairingInvitation`. | Resolved | Added `.isFinite` and upper-bound checks before integer conversion. |
| **SEC-06** | Medium | AAD Ambiguity | Variable-length string concatenation in `associatedDataPayload` without length delimiters. | Resolved | Added 2-byte big-endian length prefixing (`UInt16`) to all variable-length string fields (`senderPublicKeyHex`, `recipientPublicKeyHex`). |
| **SEC-07** | Low | Logic Bypass | IEEE-754 NaN comparison in `CommandMessage.isExpired` returned false. | Resolved | Added `guard age.isFinite else { return true }`. |
| **SEC-08** | Low | State Machine | `SequenceCounter.nextOutgoing()` trapped on reaching `UInt64.max`. | Resolved | Saturated counter at `UInt64.max` to prevent crash and signal session re-negotiation. |
| **SEC-09** | High | DoS / State Poisoning | Sequence counter state desynchronization if unauthenticated or tampered packet mutates sequence window. | Resolved | Implemented two-phase sequence validation: pre-flight check freshness before crypto, commit to state only after digital signature and AEAD decryption pass. |
| **SEC-10** | Medium | Privacy / Battery | Persistent background Bluetooth scanning or advertising causes battery drain and beacon tracking. | Resolved | Restricted CoreBluetooth strictly to foreground active windows on both platforms with 4s bounded timeouts and explicit connection cancellation. |

---

## 2. Core Architectural Invariants

1. **Zero External Dependencies:** 100% native Apple SDKs (`CryptoKit`, `Security`, `Network`, `CoreBluetooth`, `Foundation`, `SwiftUI`).
2. **Hardware Identity Isolation:** Long-term private keys reside in Secure Enclave where supported; simulator uses clearly isolated software fallback.
3. **No Persistent Background Process:** Strictly foreground lifecycle on iOS; companion window-bound lifecycle on macOS.
4. **Mutual Bilateral Authorization:** Pairing requires explicit confirmation on both devices.
5. **No Telemetry / No Cloud:** 100% local-first peer-to-peer transport over Wi-Fi/BLE.
