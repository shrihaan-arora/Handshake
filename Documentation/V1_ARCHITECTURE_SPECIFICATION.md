# HANDSHAKE — V1 Full Architecture & Protocol Specification

**Date:** 2026-11-15  
**Specification Version:** 1.0  
**Target Hardware:** iPhone 16e (Apple A18) & MacBook Air (Apple Silicon M4)  
**Target Platforms:** iOS 17.0+, macOS 14.0+  
**Implementation Language:** Swift 6  
**UI Framework:** Native SwiftUI  
**Security Frameworks:** Apple CryptoKit, Security.framework, Network.framework  

---

## 1. Product Philosophy & Capabilities

Handshake is a lightweight, local-first, peer-to-peer secure command application designed exclusively for Apple platforms. It enables an authorized iPhone to trigger exactly two administrative actions on a paired Mac:

1. **LOCK MAC:** Immediately locks the macOS display and invokes screen protection requiring password/Touch ID.
2. **SLEEP MAC:** Puts the host Mac into low-power system sleep after an orderly, authenticated handshake and network flush.

No cloud servers, no intermediate command routers, and no persistent background daemons exist in V1.

---

## 2. Cryptographic Architecture

### 2.1 Long-Term Device Identities
- **Cryptographic Primitive:** NIST P-256 (`secp256r1`) Elliptic Curve Digital Signature Algorithm (ECDSA).
- **Hardware Isolation (Secure Enclave):**
  - On physical Apple Silicon hardware (iPhone A18, Mac M4), private keys are generated in the **Secure Enclave** (`SecureEnclave.P256.Signing.PrivateKey`).
  - Access control: Protected by `kSecAccessControlPrivateKeyUsage`, bound to device biometric/passcode domain, non-exportable from hardware.
- **Simulator & Fallback Isolation:**
  - When running in an iOS Simulator or environment lacking Secure Enclave hardware, a software-backed `P256.Signing.PrivateKey` stored in the system Keychain is used.
  - The implementation strictly discloses whether the key is hardware-backed or software-emulated; simulator keys are never falsely badged as Secure Enclave keys.
- **Identity Representation (`DeviceIdentity`):**
  - Public Key: ANSI X9.62 uncompressed point encoding (65 bytes hex-encoded, `04...`).
  - Public Key Fingerprint: SHA-256 hash of public key raw bytes, formatted as `XXXX...YYYY` (uppercase hex prefix and suffix).

### 2.2 Mutual QR Device Pairing Protocol
Pairing is a strictly bilateral, single-use, out-of-band mutual authentication protocol:

```
HOST (Mac)                                                       CLIENT (iPhone)
--------------------------------------------------------------------------------
1. Generate ephemeral P-256 key (e_host, E_host)
   Generate random Nonce (16 bytes), InvitationID (UUID)
   Display QR Code:
   handshake://pair?v=1&id=...&name=...&pk=...&epk=...&port=...&nonce=...&exp=...

                                      -- [Camera Scan] -->
                                                       2. Parse QR Invitation
                                                          Verify expiration & version
                                                          Generate ephemeral (e_client, E_client)
                                                          Connect to Mac via Local TCP
                                      <-- PairingRequest --
3. Receive PairingRequest (E_client, PK_client)
   Compute ECDH SharedSecret SS = ECDH(e_host, E_client)
   Compute Transcript T = E_host || E_client || PK_host || PK_client || Nonce || InvitationID
   Derive PRK = HKDF-Extract(Salt: Nonce, IKM: SS)
   Derive SAS_full = HKDF-Expand(PRK, "Handshake-Pairing-SAS-v1" || T, 32)
   Compute 6-digit SAS = (UInt32(SAS_full[0..3]) % 1000000)
   Display SAS to User                                 Compute same SS & Transcript T
                                                       Derive identical 6-digit SAS
                                                       Display SAS to User

                      [User visually compares 6-digit SAS on both screens]

4. User taps "Confirm" on iPhone
   iPhone signs Transcript T || "CONFIRM" with Client Identity Key
                                      -- PairingConfirmation -->
5. Mac verifies Client Signature against PK_client
   Mac displays "Approve iPhone?" prompt
   User taps "Approve" on Mac
   Mac signs Transcript T || "ACCEPT" with Host Identity Key
   Mac saves Client Identity to Trust Store
   Mac invalidates InvitationID
                                      <-- PairingCompletion --
                                                       6. iPhone verifies Host Signature
                                                          iPhone saves Host Identity to Trust Store
                                                          Pairing Complete
```

- **SAS Wire Isolation Invariant:** The 6-digit Short Authentication String is **NEVER** transmitted over the network in either direction. Both devices compute it independently from the transcript and shared secret.

### 2.3 Command Transport & Authenticated Framing
Every command session uses authenticated encryption with associated data (AEAD):

1. **Session Key Agreement:**
   - Ephemeral P-256 ECDH exchange initiates the session.
   - Directional AES-256-GCM symmetric keys are derived using HKDF-SHA256:
     - $K_{client \to host} = \text{HKDF-Expand}(SS, \text{info}: "Handshake-v1-C2H-" \parallel \text{SessionID}, 32)$
     - $K_{host \to client} = \text{HKDF-Expand}(SS, \text{info}: "Handshake-v1-H2C-" \parallel \text{SessionID}, 32)$
2. **Authenticated Additional Data (AAD) Binding:**
   To prevent canonicalization delimiter collisions (SEC-06), variable-length fields are strictly length-prefixed:
   ```
   AAD = [1 byte: Version (0x01)]
       || [16 bytes: SessionUUID]
       || [8 bytes: SequenceNumber (big-endian)]
       || [8 bytes: TimestampMilliseconds (big-endian)]
       || [2 bytes: SenderPublicKeyHex length (big-endian)]
       || [N bytes: SenderPublicKeyHex (UTF-8)]
       || [2 bytes: RecipientPublicKeyHex length (big-endian)]
       || [M bytes: RecipientPublicKeyHex (UTF-8)]
   ```
3. **Payload Encryption:**
   - Ciphertext: `AES.GCM.seal(commandPayloadJSON, using: K_client2host, nonce: 12-byte random, authenticating: AAD)`
   - Tag: 16-byte Poly1305/GCM authentication tag.
4. **Digital Signature:**
   - The sender computes a NIST P-256 ECDSA signature over SHA-256 of `(AAD || Ciphertext || AuthTag)`.
5. **Anti-Replay Validation:**
   - Inbound sequence numbers are validated through `SequenceCounter` with a 1,000-frame sliding window.
   - Timestamps must satisfy $|T_{receiver} - T_{packet}| \le 30.0\text{ seconds}$.

---

## 3. Strict Application Lifecycle & Power Management

### 3.1 iPhone Application Lifecycle
- The iPhone app operates strictly in the **foreground**.
- No background execution modes (`UIBackgroundModes`) are enabled.
- No continuous Bluetooth background scanning.
- Connections are created on-demand when the user opens the application or taps a command, and networking resources are released immediately upon command receipt acknowledgment.

### 3.2 Mac Companion Lifecycle
- The companion listener operates **only when the application is running and its main window is open**.
- If the main window closes, the Network listener is stopped immediately.
- **Zero background daemons:** No `LaunchAgents`, no `LaunchDaemons`, no login items, and no hidden background processes.
- If the Mac application is closed or asleep, the iPhone honestly reports the Mac as "Unavailable".

---

## 4. Mac Command Execution Mechanisms

### 4.1 Lock Mac
- **Requirement:** User-authorized, Apple-documented mechanism without arbitrary shell scripts.
- **Mechanism:**
  - Invoke `SACLockScreenImmediate()` via dynamic symbol lookup in `/System/Library/PrivateFrameworks/login.framework` if available, OR
  - Trigger system screen lock via AppleScript / System Events (`tell application "System Events" to sleep` or screen saver lock) with explicit user automation authorization, OR
  - Invoke `/usr/bin/pmset displaysleepnow` which immediately engages display sleep and screen lock on macOS when password lock on sleep is enabled.
- **Execution Staging:**
  1. Authenticate command packet and sender identity against Trust Store.
  2. Verify sequence number freshness and timestamp.
  3. Execute lock mechanism.
  4. Transmit signed acknowledgment back to iPhone.

### 4.2 Sleep Mac
- **Requirement:** Apple-documented power management API.
- **Mechanism:**
  - `IOPMSleepSystem(mach_port_t)` from IOKit (`IOKit/pwr_mgt/IOPMLib.h`).
- **Execution Staging (Orderly Sequence):**
  1. Authenticate sleep command packet and verify sender identity against Trust Store.
  2. Prepare Mac for sleep.
  3. Transmit signed acknowledgment packet back to iPhone.
  4. Flush TCP connection buffers to guarantee delivery.
  5. Invoke `IOPMSleepSystem(kIOMasterPortDefault)`.

---

## 5. Security Invariants Summary

1. Zero external dependencies (100% native Apple SDKs).
2. Identity private keys non-exportable; rooted in Secure Enclave where hardware exists.
3. Mutual, bilateral approval required for initial trust pairing.
4. Short Authentication String never sent over network.
5. All packets cryptographically authenticated and encrypted with fresh nonces.
6. Replay, duplicate, out-of-order, and expired packets fail closed.
7. Zero persistent background daemons on either platform.
