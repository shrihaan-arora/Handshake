# HANDSHAKE — Security Engineering & Cryptographic Specification

**Specification Version:** 1.1 (Phase 1 Audit Gate Baseline)  
**Security Level:** High / Zero-Trust Local Perimeter  
**Cryptographic Framework:** Native Apple `CryptoKit.framework` exclusively

---

## 1. Cryptographic Primitives & Key Hierarchy

To ensure algorithmic consistency and take advantage of Apple hardware security silicon without mixing incompatible key families, Handshake standardizes on the **NIST P-256 (secp256r1)** suite:

| Cryptographic Role | Native Primitive | Key Size / Spec | Hardware Boundary |
| :--- | :--- | :--- | :--- |
| **Long-Term Device Identity** | `SecureEnclave.P256.Signing` | 256-bit ECC Keypair | Apple Secure Enclave (Keychain) |
| **Identity Fallback** | `P256.Signing` | 256-bit ECC Keypair | Apple Keychain (`DeviceOnly`) |
| **Ephemeral Key Agreement** | `P256.KeyAgreement` (ECDH) | 256-bit Ephemeral | Volatile Process Memory |
| **Key Derivation (KDF)** | `HKDF<SHA256>` | SHA-256 HMAC | Volatile Process Memory |
| **Authenticated Symmetric Cipher** | `AES.GCM` | 256-bit Key, 12-byte Nonce | Volatile Process Memory |
| **Short Authentication String (SAS)** | Truncated HKDF output | 6 Decimal Digits (`000 000`–`999 999`) | Human Visual Display Only |
| **Anti-Replay Window** | Monotonic Counter + Timestamp | UInt64 Counter + Int64 UTC ms | Thread-Safe Memory Actor |

> [!NOTE]
> **Secure Enclave vs Curve25519 Compatibility:**  
> Apple's Secure Enclave hardware strictly supports NIST P-256 (secp256r1). Curve25519 (Ed25519/X25519) is available in CryptoKit as software-only cryptography and cannot be isolated inside the Secure Enclave processor. Handshake uses NIST P-256 to guarantee that private identity keys never leave hardware silicon on modern iPhones and Apple Silicon Macs.

---

## 2. Key Lifecycle & Keychain Storage Rules

1. **Generation:**
   - Generated on-device at initial application launch.
   - Guarded by access control:
     ```swift
     kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
     ```
   - Marked non-exportable and excluded from iCloud Keychain syncing (`kSecAttrSynchronizable = false`).
2. **Key Agreement:**
   - Ephemeral keypairs ($K_{\text{eph}}$) are generated uniquely per pairing attempt or session.
   - Ephemeral private keys are wiped immediately upon session establishment.
3. **Revocation:**
   - Revoking a device removes its public key from the Keychain trust store.
   - Any active network or Bluetooth connections with that peer are severed immediately.

---

## 3. Secure QR Pairing Protocol (SAS Out-of-Band Verification)

The pairing protocol eliminates man-in-the-middle (MITM) vulnerabilities by requiring human visual verification of a dynamic 6-digit Short Authentication String derived independently by both devices:

```
[Mac Host]                                         [iPhone Client]
    |                                                     |
    | 1. Generate Ephemeral (Priv_m, Pub_m)               |
    |    Display QR(InvId, MacId, Pub_m, Port, Nonce)     |
    | -------------------------------------------------> | 2. Camera scans QR
    |                                                     |    Generate Ephemeral (Priv_i, Pub_i)
    | 3. PairingRequest(InvId, PhoneId, Pub_i, NonceProof)|
    | <------------------------------------------------- |
    | 4. Invalidate InvId (Single-use enforcement)        |
    | 5. PairingResponse(InvId, MacId, Pub_m)             |
    | -------------------------------------------------> |
    |                                                     |
    | [Both compute SharedSecret = ECDH() and TranscriptHash]
    | [Both derive SAS = Truncate(HKDF(SS, Transcript))] |
    |                                                     |
    | 6. Visual Display:  [ 8 4 9   2 0 1 ]               | 6. Visual Display:  [ 8 4 9   2 0 1 ]
    |    User inspects both screens                       |    User inspects both screens
    |                                                     |
    | 7. User Approves on Mac                             | 7. User Approves on iPhone
    |                                                     |
    | 8. PairingConfirmation(Approved, Sig_i(Transcript)) |
    | <------------------------------------------------- |
    | 9. PairingCompletion(Approved, Sig_m(Transcript))   |
    | -------------------------------------------------> |
    |                                                     |
    | 10. Store Pinned Public Key in Keychain             | 10. Store Pinned Public Key in Keychain
```

### Critical Security Rule:
**The SAS code is NEVER transmitted over the network.** It exists solely as an out-of-band visual verification mechanism between the two screens.

---

## 4. Replay Attack & Tampering Protections

Every command sent over local Wi-Fi or Bluetooth Low Energy is wrapped in a `CommandEnvelope`:
1. **Associated Data Binding:** The envelope binds protocol version, message UUID, monotonic sequence number, timestamp, sender public key, and recipient public key directly into the AEAD authentication tag.
2. **Freshness Window:** Timestamps exceeding 30 seconds of clock skew are rejected.
3. **Monotonic Counter:** Sequence numbers $\le$ highest sequence number seen within a 1,000-message sliding window are dropped.
4. **Repudiation Resistance:** Each command envelope carries an ECDSA digital signature signed by the sending device's hardware identity key.

---

## 5. Security Honesty & Privacy Baseline

- **Zero Third-Party Telemetry:** No analytics libraries, crash-reporting SDKs, or external network requests.
- **Fail Closed:** Any cryptographic error, signature invalidation, sequence duplicate, or expired timestamp immediately aborts the connection and logs a security event via `os.Logger(subsystem: "com.shrihaan.handshake", category: "security")`.
- **Honest UI State:** The user interface displays encryption status only after cryptographic verification has succeeded.
