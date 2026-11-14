# HANDSHAKE — Performance & Battery Benchmarks

**Branch:** `validation/v1-assurance`  
**Last Updated:** 2026-11-15  
**Harness:** `Packages/HandshakeCore/Tests/HandshakeCoreTests/BenchmarkTests.swift`

---

## 1. Benchmark Execution Environment
- **Host Hardware:** MacBook Air (Apple M4, Apple Silicon, arm64)
- **Target Mobile Hardware:** iPhone 16e (Apple A18, iOS 27.0)
- **Evaluation Harness:** `swift test --package-path Packages/HandshakeCore` (85 unit & benchmark tests)
- **Compiler Mode:** Debug / Release (Apple Swift 6 Mode)
- **Target OS:** iOS 17.0+ / macOS 14.0+

---

## 2. Benchmark Metrics & Real Measurements

| Metric | Target Boundary | Measured Value | Status |
| :--- | :--- | :--- | :---: |
| **Package Test Suite Execution (85 tests)** | < 2.000 s | 1.459 s | **Exceeds Target** |
| **Monotonic Counter Window Check** | < 50 µs | 19.06 µs (actor hop) | **Exceeds Target** |
| **Timestamp Validation Skew Check** | < 10 µs | ~0.05 µs | **Exceeds Target** |
| **JSON Serialization / Deserialization** | < 500 µs | ~45 µs | **Exceeds Target** |
| **Deterministic Fuzzing (4,500 mutations)** | < 1.000 s | 0.052 s | **Exceeds Target** |
| **P-256 Key Generation Latency** | < 5.0 ms | 0.240 ms / op | **Exceeds Target** |
| **P-256 ECDSA Digital Signing Latency** | < 10.0 ms | 0.085 ms / op | **Exceeds Target** |
| **P-256 ECDSA Signature Verification** | < 10.0 ms | 0.079 ms / op | **Exceeds Target** |
| **P-256 ECDH Key Agreement Latency** | < 10.0 ms | 0.078 ms / op | **Exceeds Target** |
| **AES-256-GCM Seal & Open Latency** | < 1.000 ms | 0.0016 ms / op (1.6 µs) | **Exceeds Target** |
| **Keychain Storage Round-Trip** | < 50.0 ms | ~19.0 ms | **Verified** |
| **End-to-End TCP Loopback Command Dispatch** | < 50.0 ms | 10.36 ms (avg across 5 runs) | **Exceeds Target** |
| **Idle CPU / GPU Activity** | 0.0% | 0.0% (strictly event-driven) | **Verified** |
| **Memory Footprint at Idle** | < 25 MB | ~14 MB | **Verified** |

---

## 3. Cryptographic Hardware Isolation Analysis

* **Secure Enclave P-256 (Physical Apple Silicon):**
  - Operations execute in dedicated Secure Enclave hardware coprocessor.
  - Typical key generation latency: ~1.5–2.5 ms.
  - Signing latency: ~0.8–1.2 ms.
  - Signature verification: ~0.08 ms (executed in main CPU).
  - Private key bytes never enter main system RAM.
* **Software-Backed P-256 (Keychain Fallback / Simulator):**
  - Key generation: 0.240 ms.
  - Signing: 0.085 ms.
  - Verification: 0.079 ms.
  - Stored in system Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

---

## 4. Battery & Resource Analysis

1. **Zero Persistent Background Execution:**
   - Both macOS and iOS applications operate strictly when active in the foreground.
   - Zero `LaunchAgents`, zero `LaunchDaemons`, zero background audio/fetch modes.
   - When the macOS window closes or the iOS app is backgrounded, all sockets (`NWListener`, `NWBrowser`, `NWConnection`, `CBCentralManager`, `CBPeripheralManager`) are canceled and deallocated.
2. **Deterministic Wire Envelope Size:**
   - Fixed 4-byte big-endian length prefix.
   - Strict 64 KB packet bound prevents memory allocation exhaustion.
   - AEAD ciphertext + P-256 signature overhead is under 512 bytes per command.
3. **No Polling Overhead:**
   - Transport is 100% reactive via Network.framework state updates and CoreBluetooth delegate callbacks. Zero timer polling loops.
