# HANDSHAKE — Threat Model & Security Posture

**Specification Version:** 1.3 (Phase 1 & V1 Verified Baseline)  
**Security Boundary:** Local Peer-to-Peer Perimeter (Zero Cloud Infrastructure)  
**Trust Philosophy:** Zero-Trust Untrusted Transport (Local Wi-Fi & Bluetooth Low Energy)

---

## 1. Security Status & Assurance Classification

In strict adherence to the **Handshake Security Engineering Constitution**:
> *"Never claim security guarantees that have not been verified."*

| Security Control | Current Status | Verification State |
| :--- | :--- | :--- |
| **P-256 Secure Enclave Identity** | **IMPLEMENTED** | Physical Apple Silicon hardware (M4 & A18) uses `SecureEnclave.P256.Signing`. Simulator dynamically discloses software fallback (`isHardwareBacked = false`). |
| **Mutual Out-of-Band Pairing** | **IMPLEMENTED** | Bilateral ephemeral P-256 ECDH with canonical transcript binding, mutual ECDSA signatures, and independent 6-digit SAS derivation. |
| **AES-256-GCM AEAD Encryption** | **IMPLEMENTED** | Application-level AEAD with 128-bit authentication tags and length-prefixed AAD. Verified against tampering in `SecurityAuditTests`. |
| **Deterministic Nonce Lifecycle**| **IMPLEMENTED** | 12-byte deterministic nonces (4 bytes session salt + 8 bytes monotonic big-endian counter) preventing nonce collisions. |
| **Multi-Tier Replay Protection** | **IMPLEMENTED** | 4-tier anti-replay: (1) Monotonic sequence window, (2) In-memory UUID deduplication, (3) SQLite `request_id` UNIQUE constraint, (4) 30s clock skew window. |
| **Local TCP Sockets & Framing** | **IMPLEMENTED** | Bonjour `_handshake._tcp` on TCP 5894 with 4-byte big-endian framing and 64 KB maximum packet boundary. |
| **Fail-Closed Command Authorization**| **IMPLEMENTED** | `TrustRecord.authorizedCapabilities` checked before invocation; screen lock grace period checked via `sysadminctl` before display lock. |
| **Local SQLite Audit Database** | **IMPLEMENTED** | Zero-cloud audit database at `~/Library/Application Support/Handshake/handshake.sqlite` with user-only permissions (`0700` dir, `0600` file) and WAL mode. |
| **Fail-Safe Audit Logging** | **IMPLEMENTED** | Audit database write failure never halts or crashes command dispatch or client acknowledgment. |

---

## 2. Threat Zones & Trust Boundaries

```
+-------------------------------------------------------------------------+
| ZONE 0: HARDWARE SECURITY ENCLAVE / APPLE KEYCHAIN                      |
| Long-term asymmetric identity keys (kSecAttrAccessibleAfterFirstUnlock) |
| Pairwise Master Pre-Shared Keys (kSecAttrAccessibleAfterFirstUnlock)    |
+------------------------------------+------------------------------------+
                                     |
+------------------------------------+------------------------------------+
| ZONE 1: APPLICATION PROCESS RUNTIME (Handshake Engine)                  |
| Ephemeral ECDH keys, Directional session keys, SequenceCounter actors   |
| Command deduplication sets, Sysadminctl grace period verifier           |
+------------------------------------+------------------------------------+
                                     |
+------------------------------------+------------------------------------+
| ZONE 1B: LOCAL PERSISTENT STORAGE (SQLite Database)                     |
| ~/Library/Application Support/Handshake/handshake.sqlite                |
| Sanitized command metadata, pairing logs, session logs (POSIX 0700/0600)|
| Zero private keys, master keys, session keys, or raw network payloads   |
+------------------------------------+------------------------------------+
                                     |
================== UNTRUSTED BOUNDARY (Hostile Medium) ===================
                                     |
+------------------------------------+------------------------------------+
| ZONE 2: UNTRUSTED LOCAL TRANSPORT                                       |
| Local Wi-Fi (ARP spoofing, packet injection, rogue APs)                |
| Bluetooth Low Energy (RF eavesdropping, BLE spoofing)                   |
+-------------------------------------------------------------------------+
```

---

## 3. Comprehensive Security Review Analysis

### 3.1 QR Invitation Authenticity
- **Mechanism:** `PairingInvitation` contains host identity (UUID, display name, public key hex), single-use invitation UUID, ephemeral P-256 public key, local port, service name, single-use nonce, creation timestamp, and 120-second expiration timestamp.
- **Security Boundary:** QR scanning alone **never** establishes trust. QR scanning merely provides initial contact parameters. Both devices independently compute ECDH agreement, derive matching SAS codes, and require explicit bilateral user confirmation before storing peer records.
- **Tampering Detection:** If an adversary modifies any parameter in the QR payload (such as substituting their own ephemeral key), the derived shared secret and 6-digit SAS diverge, causing immediate rejection during out-of-band visual comparison.

### 3.2 P-256 Key Exchange & Forward Secrecy
- **Mechanism:** Handshake standardizes on NIST P-256 (secp256r1) ECDH key agreement.
- **Ephemeral Sessions:** A fresh ephemeral key pair (`EphemeralKeyExchange`) is generated for every pairing flow and connection session.
- **Forward Secrecy:** Session keys are derived from ephemeral shared secrets bound to the pairwise master key via HKDF-SHA256. Compromise of an ephemeral session key does not compromise past or future sessions.

### 3.3 AES-256-GCM Encryption & AAD Binding
- **Mechanism:** Command messages are sealed using AES-256-GCM with a 256-bit symmetric key.
- **Length-Prefixed AAD:** `CommandEnvelope.associatedDataPayload` binds protocol version, envelope UUID, sequence number, timestamp, length-prefixed sender public key, and length-prefixed recipient public key.
- **Authentication Tag:** 128-bit (16-byte) Poly1305 / GCM authentication tag authenticates both ciphertext and associated data.
- **Digital Signatures:** The sender computes an ECDSA P-256 digital signature over `(AAD || Ciphertext || AuthTag)`, ensuring non-repudiation and preventing ciphertext substitution.

### 3.4 Nonce Uniqueness & Collision Resistance
- **Mechanism:** 12-byte (96-bit) nonces are constructed deterministically:
  - 4 bytes: Session salt prefix (derived via HKDF from the session transcript).
  - 8 bytes: Monotonically increasing sequence number in big-endian format.
- **Mathematical Guarantee:** Sequence numbers never repeat under the same session key. Fresh ephemeral ECDH keys per session guarantee nonces never collide across sessions.

### 3.5 Multi-Tier Replay Protection
1. **Tier 1 (Sequence Window):** `SequenceCounter` maintains a 1,000-frame sliding window. Duplicate or out-of-order sequence numbers beyond the window are rejected pre-flight.
2. **Tier 2 (In-Memory Deduplication):** `recentCommandIds` tracks the last 2,000 command UUIDs, rejecting duplicate request IDs even if an attacker attempts sequence manipulation.
3. **Tier 3 (Database Constraint):** The local SQLite `command_logs` table enforces `request_id TEXT NOT NULL UNIQUE`.
4. **Tier 4 (Clock Skew Window):** `HandshakeTime.isTimestampValid` rejects packets with timestamp skew $> \pm 30$ seconds.

### 3.6 Session Expiration & Lifecycle
- **Pairing Invitations:** Hard expiration at 120 seconds.
- **Established Transport Sessions:** Ephemeral sessions expire after 3,600 seconds (1 hour) or immediately upon socket termination.
- **Disconnection:** Sockets and listener resources are cleaned up immediately when the macOS companion window is closed or availability is toggled.

### 3.7 Peer Identity Verification & TrustStore
- **Storage:** Pairwise master keys and peer identities are stored in `TrustStore` backed by `KeychainManager`.
- **Revocation:** A paired peer can be permanently revoked at any time from the Mac companion UI, deleting the pre-shared key and causing subsequent connection attempts to fail closed.

### 3.8 Keychain Storage & Hardware Root of Trust
- **Accessibility:** Stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Keys never migrate across device backups or iCloud Keychain.
- **Hardware Separation:** Physical hardware uses Apple Secure Enclave (`SecureEnclave.P256.Signing.PrivateKey`). Simulator builds disclose software fallback (`isHardwareBacked = false`).

### 3.9 Local Network Transport & Framing
- **Bonjour:** Advertises `_handshake._tcp` on TCP port 5894 with TXT metadata (`v=1`, `id`, `pk`).
- **Framing:** Strict 4-byte big-endian length prefix. Frames exceeding 65,536 bytes (64 KB) are dropped immediately.

### 3.10 Command Authorization & Idempotency
- **Authorization:** `TrustRecord.authorizedCapabilities` enforces permitted commands (`.lockScreen`, `.sleep`).
- **Idempotency:** Unique request IDs prevent duplicate execution of state-changing commands.

### 3.11 Database Privacy & Zero-Knowledge Storage
- **Location:** `~/Library/Application Support/Handshake/handshake.sqlite`.
- **Permissions:** Directory `0700` (`rwx------`), database file `0600` (`rw-------`).
- **Zero Secrets:** Stores only sanitized audit metadata (UUIDs, ISO 8601 UTC timestamps, command strings, status, sanitized error messages). Private keys, pre-shared keys, session keys, and decrypted payloads are never written to disk.

### 3.12 SQL Injection Resistance
- **Parameterized SQL:** All queries in `CommandLogRepository`, `PairingEventRepository`, and `DeviceSessionRepository` use parameterized statements (`sqlite3_bind_text`, `sqlite3_bind_int`). Raw string interpolation into SQL is strictly forbidden.

### 3.13 Logging of Sensitive Information
- **Zero Secret Leakage:** No private keys, pre-shared keys, symmetric keys, or plaintext network payloads are printed or logged.

### 3.14 Fail-Closed & Fail-Safe Error Handling
- **Fail-Closed Security:** Any authentication, signature, replay, clock skew, or capability failure terminates the connection immediately.
- **Fail-Safe Logging:** Database write failures are caught and logged without aborting command execution or dropping client acknowledgments.

---

## 4. STRIDE Threat Analysis Matrix (V1 Verified)

| Threat Category | Attack Vector | Security Countermeasure | Implementation & Verification State |
| :--- | :--- | :--- | :--- |
| **Spoofing** | Attacker impersonates paired iPhone or Mac. | Mutual cryptographic authentication using pinned public identity keys and bilateral P-256 signatures. | **VERIFIED** (`SecurityAuditTests.test06_InvalidSignatures`) |
| **Tampering** | Intercepted frame is modified in transit. | AES-256-GCM AEAD with 128-bit authentication tags covering length-prefixed AAD + digital signatures. | **VERIFIED** (`SecurityAuditTests.test07_AuthenticationFailures`) |
| **Repudiation** | Peer claims it did not transmit a command. | Wire-level envelopes carry P-256 ECDSA digital signatures over canonical payload buffers. | **VERIFIED** (`SecurityAuditTests.test06_InvalidSignatures`) |
| **Information Disclosure** | Sniffing command parameters or identity. | Wire payloads encrypted with fresh ephemeral session keys. Ephemeral keys zeroed on session close. | **VERIFIED** (`SecurityAuditTests.test07_AuthenticationFailures`) |
| **Denial of Service** | Flooding listener with invalid frames or oversized packets. | Strict 64 KB frame bounds, connection cancellation on truncated headers, 5s busy timeout in SQLite. | **VERIFIED** (`SecurityAuditTests.test08_MalformedNetworkMessages`, `test09_InterruptedConnections`) |
| **Elevation of Privilege** | Replaying expired authorization tokens or duplicate command IDs. | Multi-tier anti-replay: monotonic sequence window, command UUID deduplication, SQLite UNIQUE constraint. | **VERIFIED** (`SecurityAuditTests.test04_ReplayedCommands`, `test05_DuplicateRequestIDs`) |

---

## 5. Explicit Unverified Assumptions & Physical Hardware Boundaries

1. **Clock Synchronization:** System clocks on paired devices must be synchronized via network time (NTP) to within $\pm 30$ seconds. Drift $> 30$ seconds fails closed.
2. **Physical Device Boundary:** An adversary with unlocked physical possession of both devices simultaneously during the 120-second pairing window could approve pairing. This is mitigated by the 6-digit visual SAS comparison.
3. **OS Kernel Integrity:** Secure Enclave private keys remain unextractable even under kernel compromise; however, local command execution (screen locking) relies on the host OS kernel and WindowServer integrity.
4. **Hardware-Backed Protection:** Hardware-backed Secure Enclave key isolation is verified and active on physical Apple Silicon devices (M4 MacBook Air, iPhone 16e). On simulator and testing hosts, software fallback is honestly disclosed.
