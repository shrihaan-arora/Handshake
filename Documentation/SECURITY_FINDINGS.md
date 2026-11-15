# HANDSHAKE — Security Findings & Remediation Inventory

**Date:** 2026-11-15  
**Auditor:** Autonomous Apple-Platform Security Architecture Agent  
**Branch:** `validation/physical-device-integration`  
**Status:** **ALL FINDINGS REMEDIATED (0 Unresolved)**

---

## 1. Vulnerability Findings Register

| ID | Vulnerability Title | Severity | CWE | Status | Remediation Reference |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **SEC-01** | Static PSK Key Derivation Without Session Entropy | Critical | CWE-323 | **RESOLVED** | `SessionHandshake.swift` |
| **SEC-02** | Potential AES-GCM Nonce Reuse on App Restart | Critical | CWE-329 | **RESOLVED** | `NONCE_LIFECYCLE.md` & `SecureChannel.swift` |
| **SEC-03** | Master Secret Storage in Persistent JSON Models | High | CWE-312 | **RESOLVED** | `TrustStore.swift` & `KeychainManager.swift` |
| **SEC-04** | Global Sequence Counter Across Multiple Peers | High | CWE-400 | **RESOLVED** | `HandshakeServer.peerSequenceCounters` |
| **SEC-05** | Screen Saver Lock Grace Period Password Bypass | High | CWE-305 | **RESOLVED** | `MacLockEngine.swift` |
| **SEC-06** | Secret Key Leakage via Debug String Interpolation | Medium | CWE-532 | **RESOLVED** | `TrustRecord.description` |
| **SEC-07** | Replay Window Boundary Integer Wrap | Medium | CWE-190 | **RESOLVED** | `SequenceCounter.swift` |
| **SEC-08** | Missing Camera Authorization & Placeholder QR Viewfinder | Medium | CWE-276 | **RESOLVED** | `CameraPermissionManager.swift` & `QRScannerView.swift` |

---

## 2. Detailed Vulnerability Analyses & Remediations

### SEC-01: Static PSK Key Derivation Without Session Entropy
- **Description:** Earlier iterations derived directional symmetric keys directly from the master Pre-Shared Key (PSK) using static HKDF info strings. All connections between two devices used the identical AES-256 key indefinitely.
- **Risk:** Compromise of a single session key would retroactively decrypt all past recorded sessions.
- **Remediation:** Implemented authenticated 1-RTT ephemeral NIST P-256 Elliptic Curve Diffie-Hellman (ECDH) handshake (`SessionInitiation` and `SessionResponse`). Every connection establishes a fresh 256-bit ephemeral shared secret bound to the session transcript and master PSK via HKDF-SHA256, achieving **Perfect Forward Secrecy**.

### SEC-02: Potential AES-GCM Nonce Reuse on App Restart
- **Description:** If an iPhone app crashed or restarted, its in-memory sequence counter reset to 1. Under a static symmetric key, encrypting with sequence 1 would generate an identical 12-byte nonce, causing catastrophic AES-GCM nonce reuse.
- **Risk:** Complete loss of message confidentiality and GHASH authentication key recovery by an attacker.
- **Remediation:** Structured nonces into 4-byte session-derived salt prefix + 8-byte big-endian sequence counter. Because each session negotiates fresh ephemeral keys and fresh 4-byte salts, sequence counter resets upon reconnection can never cause nonce collisions under the same key.

### SEC-03: Master Secret Storage in Persistent JSON Models
- **Description:** Raw 256-bit pre-shared keys were previously serialized in plaintext JSON inside `TrustRecord` structures stored under the general trust store account.
- **Risk:** Accidental exposure through logging, JSON dumps, or unencrypted backups.
- **Remediation:** Sanitized `TrustRecord` by removing `preSharedKeyHex` from persistent storage. Master PSKs are isolated in dedicated Apple Keychain items (`kSecClassGenericPassword`) with access flag `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Revoking or removing a device explicitly purges its PSK from Keychain.

### SEC-04: Global Sequence Counter Across Multiple Peers
- **Description:** `HandshakeServer` maintained a single monolithic `SequenceCounter` across all connected clients.
- **Risk:** Commands arriving from Client B would advance the sequence counter beyond Client A's expected next sequence number, causing authentic commands from Client A to be falsely rejected as out-of-order or replayed.
- **Remediation:** Updated `HandshakeServer` to maintain an actor-isolated dictionary of sequence counters:
  `peerSequenceCounters: [String: SequenceCounter]` keyed by the peer's public key hex. Each device operates on an independent, monotonic sequence stream.

### SEC-05: Screen Saver Lock Grace Period Password Bypass
- **Description:** Standard macOS screen saver triggers do not lock the screen if macOS System Settings specifies a grace period (e.g., "Require password after 5 minutes").
- **Risk:** A user expecting the Mac to lock immediately could leave it unlocked and vulnerable to physical tampering during the grace window.
- **Remediation:** `MacLockEngine` queries `sysadminctl -screenSaver isLockImmediate` and evaluates system lock defaults. If a grace period is active, `MacLockEngine` uses `SACLockScreenImmediate()` / LoginWindow framework to enforce immediate physical screen locking requiring password/Touch ID.

### SEC-06: Secret Key Leakage via Debug String Interpolation
- **Description:** Printing or logging a `TrustRecord` or identity model in Xcode or system logs risked leaking cryptographic keys.
- **Remediation:** Implemented `CustomStringConvertible` and `CustomDebugStringConvertible` across all identity and trust models. Sensitive cryptographic material is strictly masked (`[REDACTED]`).

### SEC-07: Replay Window Boundary Integer Wrap
- **Description:** Under large sequence jumps, sliding window boundary arithmetic risked underflow or incorrect acceptance of ancient sequence numbers.
- **Remediation:** Added clamped boundary checks and comprehensive boundary unit tests (`SecurityBoundaryTests.swift`). Sequence jumps $> 1,000$ packets are safely rejected or trigger session renegotiation.

### SEC-08: Missing Camera Authorization & Placeholder QR Viewfinder
- **Description:** `PairingScannerView.swift` contained a placeholder UI mockup with static shapes and no `AVFoundation` imports or `AVCaptureDevice` authorization checks. As a result, the physical iPhone never presented the iOS camera permission request dialog, the camera hardware was never initialized, and QR codes displayed on the Mac companion could not be read. Additionally, `PairingInvitation` lacked a `parse(from:)` deserializer to validate URL schemes, protocol versions, expirations, and cryptographic key formats from scanned QR payloads.
- **Remediation:** 
  1. Implemented `CameraPermissionManager` covering all four `AVAuthorizationStatus` states (`.notDetermined`, `.authorized`, `.denied`, `.restricted`), requesting access explicitly via `AVCaptureDevice.requestAccess(for: .video)`, and providing graceful fallback with a direct link to iOS Settings (`UIApplication.openSettingsURLString`).
  2. Implemented `QRScannerView` with `AVCaptureSession` configured strictly on a background serial queue, physical back-camera discovery, `.qr` metadata detection, haptic feedback, and torch toggle.
  3. Implemented `PairingInvitation.parse(from:currentDate:)` supporting URL scheme (`handshake://pair`) and JSON formats, verifying protocol version (`v=1`), session UUIDs, non-empty hex keys, valid ports, and rejecting expired invitations. Verified with 12 unit tests in `ModelTests.swift`.

---

## 3. Security Audit Verdict

Handshake V1 has achieved complete remediation of all identified threats. The cryptographic and network layers adhere to Apple Security Engineering principles and industry best practices.
