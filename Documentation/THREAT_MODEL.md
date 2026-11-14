# HANDSHAKE — Threat Model & Security Posture

**Specification Version:** 1.0 (Phase 1 Baseline)  
**Security Boundary:** Local Peer-to-Peer Perimeter  
**Trust Philosophy:** Zero-Trust Untrusted Transport (Local Wi-Fi & BLE)

---

## 1. System Scope & Assets

Handshake enables an iPhone to control a paired MacBook (lock screen, sleep, status query) over direct local Wi-Fi and Bluetooth Low Energy.

### Critical Assets to Protect:
1. **Host Control Authority:** Unauthorized execution of lock or sleep commands.
2. **Device Private Identity Keys:** Asymmetric signing and agreement keys held on device.
3. **Command Authenticity & Integrity:** Ensuring commands originate strictly from the verified paired device and have not been altered in transit.
4. **User Privacy:** Preventing location tracking or metadata surveillance via local Wi-Fi / BLE broadcasts.

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
   - *Mitigation:* Dual-layer encryption (TLS 1.3 at transport layer + AES-256-GCM / Poly1305 AEAD payload encryption at application layer).

2. **Active Network Adversary (MITM):**
   - Intercepts packets, tampers with payloads, drops frames, injects forged packets, establishes rogue Wi-Fi AP.
   - *Mitigation:* Pinned peer public keys; certificate pinning; AEAD authentication tags over headers and payloads; visual 6-digit Short Authentication String (SAS) during pairing.

3. **Replay Adversary:**
   - Records legitimate encrypted commands (e.g., "Lock Screen") and re-transmits them at a later time.
   - *Mitigation:* Monotonically increasing sequence counters per session (`SequenceCounter`) + strict 30-second timestamp validity window (`HandshakeTime`).

4. **Stolen / Disposed Device Adversary:**
   - An iPhone is lost or compromised.
   - *Mitigation:* Instant local device revocation on Mac (`TrustRecord.revoke()`), tearing down active sessions and dropping any frames signed by that key.

---

## 4. STRIDE Threat Analysis Matrix

| Threat Category | Attack Vector | Security Countermeasure | Verification Target |
| :--- | :--- | :--- | :--- |
| **Spoofing** | Attacker impersonates paired iPhone or Mac. | Mutual cryptographic authentication using pinned public identity keys. | `testUnauthorizedDeviceRejection` |
| **Tampering** | Intercepted frame is modified in transit. | Authenticated Encryption (AEAD) with 128-bit authentication tags covering headers and payload. | `testModifiedPacketRejection` |
| **Repudiation** | Peer claims it did not transmit a command. | Wire-level envelopes carry cryptographic digital signatures. | `testCommandSignatureValidation` |
| **Information Disclosure** | Sniffing command parameters or identity. | Wire payloads are encrypted with ephemeral session keys. | `testCiphertextEntropy` |
| **Denial of Service** | Flooding listener with invalid frames or connections. | Strict frame size bounds, unauthenticated connection timeouts, zero allocation before header validation. | `testMalformedFrameRateLimiting` |
| **Elevation of Privilege** | Replaying expired authorization tokens. | Anti-replay sequence window + timestamp expiry checking. | `testReplayedPacketRejection` |

---

## 5. Security Invariants (Fail-Closed)

- If an incoming packet's sequence number is $\le$ the highest seen within the window, the packet is silently dropped and an audit log event is recorded.
- If clock skew exceeds 30 seconds, the packet is rejected.
- If public key is not in `TrustRecord` store, connection is terminated immediately.
- Private keys NEVER leave Keychain or Secure Enclave.
- Zero analytics, zero cloud dependencies, zero telemetry.
