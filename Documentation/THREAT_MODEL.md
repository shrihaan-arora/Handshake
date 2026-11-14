# HANDSHAKE — Threat Model & Security Posture

**Specification Version:** 1.2 (Phase 1 Hardened Baseline)  
**Security Boundary:** Local Peer-to-Peer Perimeter  
**Trust Philosophy:** Zero-Trust Untrusted Transport (Local Wi-Fi & BLE)

---

## 1. Security Status & Assurance Classification

In strict adherence to the **Handshake Security Engineering Constitution**:
> *"Never claim security guarantees that have not been verified."*

| Security Control | Current Status | Verification State |
| :--- | :--- | :--- |
| **Monotonic Replay Window** | **IMPLEMENTED** | Verified by 21 package unit tests (`SequenceCounter`, sliding window 1,000). |
| **Timestamp Freshness Gate** | **IMPLEMENTED** | Verified by unit tests (`HandshakeTime`, max skew $\le$ 30s). |
| **Invitation TTL Boundaries** | **IMPLEMENTED** | Verified by unit tests (`PairingInvitation.isExpired`, 120s limit). |
| **Envelope Metadata Binding** | **IMPLEMENTED** | Verified by unit tests (`CommandEnvelope.associatedDataPayload`). |
| **P-256 Secure Enclave Keypair** | **ARCHITECTURAL DECISION** | Documented & scheduled for Phase 2 (P-256 selected over Curve25519 for hardware isolation). |
| **Mutual Out-of-Band Pairing** | **ARCHITECTURAL DECISION** | Protocol specified with independent local SAS derivation. Scheduled for Phase 2. |
| **Wire Payload AEAD Encryption**| **PLANNED (Phase 2)** | AES-256-GCM cipher pipeline to be implemented in Phase 2. |
| **Local TLS & BLE Network Sockets**| **PLANNED (Phase 3)** | Transport listeners to be implemented in Phase 3. |

---

## 2. Threat Zones & Trust Boundaries

```
+-------------------------------------------------------------------------+
| ZONE 0: HARDWARE SECURITY ENCLAVE / APPLE KEYCHAIN                      |
| Long-term asymmetric identity keys (kSecAttrAccessibleAfterFirstUnlock) |
+------------------------------------+------------------------------------+
                                     |
+------------------------------------+------------------------------------+
| ZONE 1: APPLICATION PROCESS RUNTIME (Handshake Engine)                  |
| Ephemeral session keys, Replay Counter actor, Command dispatcher       |
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

## 3. Attacker Capabilities & Models

1. **Passive LAN/RF Eavesdropper:**
   - Observes all 802.11 and 2.4 GHz BLE frames.
   - *Mitigation (Planned Phase 2/3):* Dual-layer encryption (TLS 1.3 at transport layer + AES-256-GCM AEAD payload encryption at application layer).

2. **Active Network Adversary (MITM):**
   - Intercepts packets, tampers with payloads, drops frames, injects forged packets, establishes rogue Wi-Fi AP.
   - *Mitigation (Planned Phase 2):* Pinned peer public keys; certificate pinning; AEAD authentication tags over headers and payloads; visual 6-digit Short Authentication String (SAS) during pairing.

3. **Replay Adversary:**
   - Records legitimate encrypted commands (e.g., "Lock Screen") and re-transmits them at a later time.
   - *Mitigation (Implemented in Phase 1):* Monotonically increasing sequence counters per session (`SequenceCounter`) + strict 30-second timestamp validity window (`HandshakeTime`).

4. **Stolen / Disposed Device Adversary:**
   - An iPhone is lost or compromised.
   - *Mitigation (Implemented in Phase 1):* Local device revocation model on Mac (`TrustRecord.revoke()`), invalidating trusted peer records and dropping any future frames signed by that key.

---

## 4. STRIDE Threat Analysis Matrix

| Threat Category | Attack Vector | Security Countermeasure | Implementation Stage |
| :--- | :--- | :--- | :--- |
| **Spoofing** | Attacker impersonates paired iPhone or Mac. | Mutual cryptographic authentication using pinned public identity keys. | Planned (Phase 2) |
| **Tampering** | Intercepted frame is modified in transit. | Authenticated Encryption (AEAD) with 128-bit authentication tags covering headers and payload. | Planned (Phase 2) |
| **Repudiation** | Peer claims it did not transmit a command. | Wire-level envelopes carry cryptographic digital signatures. | Planned (Phase 2) |
| **Information Disclosure** | Sniffing command parameters or identity. | Wire payloads are encrypted with ephemeral session keys. | Planned (Phase 2) |
| **Denial of Service** | Flooding listener with invalid frames or connections. | Strict frame size bounds, unauthenticated connection timeouts, zero allocation before header validation. | Planned (Phase 3) |
| **Elevation of Privilege** | Replaying expired authorization tokens. | Anti-replay sequence window + timestamp expiry checking. | **Implemented & Tested (Phase 1)** |

---

## 5. Explicit Unverified Assumptions & Limitations

1. **Clock Synchronization:** Handshake assumes system clocks on paired devices are synchronized via network time (NTP) to within $\pm 30$ seconds. If a device clock drifts $> 30$ seconds, command validation will fail closed.
2. **Physical Device Boundary:** If an attacker gains unlocked physical possession of both devices simultaneously during the 120-second QR pairing window, they could approve rogue pairing. This risk is minimized by the 6-digit visual SAS comparison.
3. **OS Kernel Integrity:** Security Enclave keys remain unextractable even under kernel compromise; however, local command execution (screen locking) relies on the host OS kernel and WindowServer integrity.
4. **Radio Proximity Is Not Authentication:** BLE presence indicates physical proximity only; Handshake treats the entire wireless medium as hostile until authenticated envelopes are verified.
