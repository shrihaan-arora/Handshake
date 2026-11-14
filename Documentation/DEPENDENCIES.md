# HANDSHAKE — Dependency Inventory & Supply Chain Integrity

**Last Updated:** Phase 1 Foundation  
**Policy:** Strict Zero-Third-Party Dependencies Policy  
**Status:** 100% Native Apple Frameworks Verified

---

## 1. External Dependencies Policy

In compliance with the **Handshake Security Engineering Constitution**:
1. Never blindly install an unknown GitHub repository.
2. Do not execute downloaded installation scripts without inspection.
3. Do not install arbitrary precompiled binaries.
4. Prefer native Apple frameworks.
5. When external source code is required, inspect it before integration.
6. Pin dependencies to exact versions or immutable commit hashes.
7. Verify release signatures and checksums when independently available.
8. Maintain a dependency inventory with source, commit, license and checksum.
9. Respect open-source licenses.
10. Never silently introduce new dependencies.

---

## 2. Dependency Inventory (Phase 1)

| Name | Source / Provider | Version / SDK | Purpose | License | Integrity Verification |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **SwiftUI** | Apple Inc. (Native OS) | iOS 17+ / macOS 14+ | Declarative user interface | Apple Proprietary OS Component | Apple Platform SDK Signed |
| **Foundation** | Apple Inc. (Native OS) | iOS 17+ / macOS 14+ | Core data structures & types | Apple / Apache 2.0 (Swift) | Apple Platform SDK Signed |
| **CryptoKit** | Apple Inc. (Native OS) | iOS 17+ / macOS 14+ | Curve25519, AES-GCM, HKDF, SHA | Apple Proprietary OS Component | Apple Platform SDK Signed |
| **Network.framework** | Apple Inc. (Native OS) | iOS 17+ / macOS 14+ | Direct peer TLS & Bonjour | Apple Proprietary OS Component | Apple Platform SDK Signed |
| **CoreBluetooth** | Apple Inc. (Native OS) | iOS 17+ / macOS 14+ | BLE peripheral & central transport | Apple Proprietary OS Component | Apple Platform SDK Signed |
| **Security.framework** | Apple Inc. (Native OS) | iOS 17+ / macOS 14+ | Secure Enclave & Keychain storage | Apple Proprietary OS Component | Apple Platform SDK Signed |
| **CoreImage** | Apple Inc. (Native OS) | iOS 17+ / macOS 14+ | Native QR code generation filter | Apple Proprietary OS Component | Apple Platform SDK Signed |
| **OSLog** | Apple Inc. (Native OS) | iOS 17+ / macOS 14+ | Unified privacy-preserving logging | Apple Proprietary OS Component | Apple Platform SDK Signed |

---

## 3. Third-Party Libraries

- **Total 3rd-Party Dependencies:** `0`
- **External SPM Packages:** `None`
- **CocoaPods / Carthage:** `None`
- **Dynamic Binary Frameworks:** `None`

---

## 4. Supply Chain Audit Procedures

Whenever an external dependency is evaluated for future milestones:
- [ ] Source repository must be cloned to an isolated review environment.
- [ ] License must be verified compatible (MIT, Apache-2.0, BSD-3-Clause).
- [ ] Immutable commit hash pinned in `Package.swift`.
- [ ] Static analysis and manual source inspection performed for hidden telemetry, backdoors, or unauthenticated network calls.
- [ ] Git commit signatures verified against developer public keys.
- [ ] Checksums documented in this inventory prior to merge.
