# HANDSHAKE — Security Engineering & Cryptographic Specification

---

## 1. Cryptographic Standards

Handshake adheres strictly to Apple-native cryptographic primitives provided by `CryptoKit.framework`:

- **Identity Keypairs:** Ed25519 (`Curve25519.Signing`) or P-256 (`P256.Signing`).
- **Key Agreement:** X25519 (`Curve25519.KeyAgreement`).
- **Key Derivation:** HKDF with HMAC-SHA256 (`HKDF<SHA256>`).
- **Authenticated Symmetric Encryption:** AES-256-GCM or ChaCha20-Poly1305.
- **Short Authentication String (SAS):** Truncated HKDF output formatted into 6 numeric digits for human visual confirmation.

---

## 2. Key Lifecycle & Storage

1. **Generation:** Keypairs are generated on-device at first launch using hardware random number generators (`SecRandomCopyBytes`).
2. **Storage:**
   - Keys are stored in the Apple Keychain using `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
   - Keys are marked non-exportable and excluded from iCloud Keychain backups (`kSecAttrSynchronizable = false`).
3. **Session Keys:** Ephemeral session keys exist purely in volatile memory and are cleared when a connection terminates.
4. **Revocation:** When a device is revoked, its pinned public key is marked revoked or deleted from the trust store. Any active transport sessions are aborted immediately.

---

## 3. QR Pairing Protocol Specification

```
[Mac Host]                                         [iPhone Client]
    |                                                     |
    | 1. Generate Ephemeral Key (X_mac)                   |
    |    Display QR(InvitationId, PubKey, Port, Nonce)    |
    | -------------------------------------------------> | 2. Camera scans QR
    |                                                     |    Generate Ephemeral (X_phone)
    | 3. PairingRequest(X_phone, NonceProof)              |
    | <------------------------------------------------- |
    | 4. Compute Shared Secret SS = ECDH(X_mac, X_phone)  |
    |    Derive SAS = Truncate(HKDF(SS))                  |
    |    PairingResponse(SAS)                             |
    | -------------------------------------------------> | 5. Compute SS & SAS
    |                                                     |
    | 6. Visual Confirmation: [ 8 4 9   2 0 1 ]           | 6. Visual Confirmation: [ 8 4 9   2 0 1 ]
    |    User approves on Mac                             |    User approves on iPhone
    |                                                     |
    | 7. Mutual Trust Pinning                             | 7. Mutual Trust Pinning
    |    Store Public Keys in Keychain                    |    Store Public Keys in Keychain
```

---

## 4. Privacy & Audit Logging Rules

1. **No Sensitive Data in Logs:** Cryptographic nonces, keys, tokens, and raw payloads are NEVER emitted to console or disk.
2. **Apple Unified Logging:** All security events are logged via `os.Logger(subsystem: "com.shrihaan.handshake", category: "security")` using standard privacy modifiers (e.g. `%{private}@` for device names if applicable).
3. **Zero Telemetry:** The application contains zero network analytics, zero third-party SDKs, and zero external crash reporting endpoints.
