# HANDSHAKE — Transport Security Evaluation: Application-Level AEAD vs. TLS 1.3

**Date:** 2026-11-15  
**Auditor:** Autonomous Apple-Platform Security Architecture Agent  
**Branch:** `validation/physical-device-integration`  
**Status:** **PASS**

---

## 1. Scope & Objective

Evaluate the transport security architecture for Handshake V1 on Apple platforms (macOS 14+ and iOS 17+), comparing two candidate models:
- **Architecture A (Implemented):** Custom Application-Level AEAD (AES-256-GCM + P-256 ECDSA + Ephemeral P-256 ECDH + Monotonic Sequence Counters) over raw TCP framing.
- **Architecture B (Alternative):** Transport Layer Security (TLS 1.3) via Apple `Network.framework` (`sec_protocol_options` and Security framework).

---

## 2. Evaluation Questions & Analysis

### Question 1: Is application-level AEAD over plaintext TCP sufficient for local Wi-Fi?
**Yes.**  
In an untrusted or hostile local network environment (e.g. coffee shop Wi-Fi or compromised home router), underlying IP packets can be sniffed or injected by third parties. Handshake treats the transport network as completely zero-trust:
- All command envelopes are encrypted with AES-256-GCM.
- An eavesdropper on the local Wi-Fi subnet observes only random-looking AEAD ciphertext and public session identifiers.
- An active attacker attempting to alter or inject packets is blocked by both the GHASH authentication tag and the outer P-256 ECDSA digital signature over `(AAD || Ciphertext || AuthTag)`.
- Replay attacks are defeated by monotonic sequence counters and session replay caches.
- Confidentiality, authenticity, integrity, and forward secrecy are achieved entirely at the application layer.

### Question 2: Does TLS 1.3 provide superior channel security?
**Marginally in traffic analysis resistance; equivalent in cryptographic strength.**  
- **Cryptographic Primitives:** Both TLS 1.3 and Handshake's application-level AEAD utilize NIST P-256 (or Curve25519) ECDH for ephemeral key agreement, HKDF-SHA256 for key derivation, and AES-256-GCM for authenticated encryption.
- **Metadata Protection:** TLS 1.3 encrypts handshake certificates and record metadata, hiding more protocol-level headers than custom framing.
- **Complexity Trade-Off:** Standard TLS 1.3 implementations rely on X.509 certificate parsing, ASN.1 decoding, and complex state machines. Flaws in ASN.1 parsers and certificate path validation are historically a major source of critical CVEs. Handshake's lightweight JSON and binary framing avoids ASN.1 complexity altogether.

### Question 3: How can TLS 1.3 mutual authentication (mTLS) work without a PKI / certificate authority?
**Via On-Device Self-Signed Identity Certificates Bound to the Trust Store.**  
In a peer-to-peer personal app like Handshake, there is no centralized Certificate Authority (CA) or public PKI:
1. Each device generates a self-signed X.509 certificate backed by its local P-256 identity key stored in Apple Keychain (`SecKeyGeneratePair` / `SecIdentityCreate`).
2. During the QR code pairing ceremony, devices exchange public keys / certificate SHA-256 fingerprints directly.
3. In `Network.framework`, `sec_protocol_options_set_verify_block` intercepts TLS handshake validation, bypassing system CA trust roots and matching the peer's leaf certificate against the pinned public key in `TrustStore`.
4. While feasible, this requires significant low-level CoreFoundation/Security C APIs (`sec_identity_t`, `SecTrustEvaluateWithError`, `SecCertificateCreateWithData`) which introduces platform maintenance overhead and fragile edge cases across iOS versions.

### Question 4: Is TLS 1.3 supported across both Network.framework and Bluetooth Low Energy?
**No.**  
- `Network.framework` natively supports TLS 1.3 over TCP (`nw_parameters_create_secure_tcp`).
- However, standard CoreBluetooth GATT / ATT transports operate with small Maximum Transmission Units (MTUs) typically ranging between 23 and 512 bytes. Standard TLS 1.3 handshakes (exchanging certificate chains and extensions) typically require 2 to 6 KB of handshake records, requiring complex packet fragmentation, reassembly, and retransmission logic over BLE attributes.
- Conversely, Handshake's custom application-level AEAD framing (`NetworkFraming.swift` and `SessionHandshake.swift`) is transport-agnostic: the exact same serialization, signing, and encryption models run natively over TCP, BLE L2CAP channels, and CoreBluetooth GATT characteristics.

### Question 5: Which architecture provides superior real-world reliability and security for V1?
**Architecture A (Application-Level AEAD) provides superior real-world reliability and security for V1.**  
1. **Zero External Dependencies:** Built 100% on native Apple `CryptoKit` and `Network.framework`.
2. **Deterministic Security Verification:** Every cryptographic property (ECDH ephemeral secret, HKDF derivation, 12-byte deterministic nonce, sequence counter window, AEAD tag, ECDSA signature) is explicitly testable and auditable in unit and adversarial test suites (122 automated tests).
3. **Transport Homogeneity:** Seamless parity between local Wi-Fi and Bluetooth Low Energy without maintaining disparate security stacks.
4. **Minimal Attack Surface:** Eliminates ASN.1 decoding, X.509 chain parsing, and complex OpenSSL/BoringSSL legacy baggage.

---

## 3. Final Recommendation & Future Roadmap

- **V1 (Current Implementation):** Retain Architecture A with the ephemeral P-256 ECDH 1-RTT session handshake (`SessionHandshake.swift`), 12-byte deterministic nonce construction (`NONCE_LIFECYCLE.md`), and Keychain-isolated PSK storage (`TrustStore.swift`).
- **V2 (Future Roadmap):** If remote internet connectivity (relay or Apple Push Notification-triggered direct connection) is introduced in V2, evaluate wrapping the transport in TLS 1.3 with pinned leaf certificates or Apple `NWProtocolFramer` to satisfy enterprise firewall and NAT-traversal requirements.
