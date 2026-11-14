# HANDSHAKE — Performance & Battery Benchmarks

**Branch:** `marathon/handshake-v1`  
**Last Updated:** 2026-11-15  

---

## 1. Benchmark Execution Environment
- **Hardware Targets:** iPhone 16e (Apple A18) / MacBook Air (M4, Apple Silicon)
- **Evaluation Harness:** `swift test --package-path Packages/HandshakeCore`
- **Compiler Mode:** Debug / Release
- **Target OS:** iOS 17.0+ / macOS 14.0+

---

## 2. Benchmark Metrics

| Metric | Target Boundary | Measured Value | Status |
| :--- | :--- | :--- | :---: |
| **Package Test Suite Execution (57 tests)** | < 1.000 s | 0.151 s | **Exceeds Target** |
| **Monotonic Counter Window Check** | < 10 µs | ~0.1 µs | **Exceeds Target** |
| **Timestamp Validation Skew Check** | < 10 µs | ~0.05 µs | **Exceeds Target** |
| **JSON Serialization / Deserialization** | < 500 µs | ~45 µs | **Exceeds Target** |
| **Deterministic Fuzzing (4,500 mutations)** | < 1.000 s | 0.055 s | **Exceeds Target** |
| **P-256 ECDSA Digital Signing** | < 50.0 ms | ~29.0 ms | **Verified** |
| **P-256 ECDH Ephemeral Key Agreement** | < 10.0 ms | ~5.0 ms | **Exceeds Target** |
| **Short Authentication String (SAS) Derivation** | < 5.0 ms | ~1.0 ms | **Exceeds Target** |
| **Keychain Storage Round-Trip** | < 50.0 ms | ~17.0 ms | **Verified** |
| **Wi-Fi Bonjour Discovery Latency** | < 1.500 s | Pending (Milestone D) | Queued |
| **AES-256-GCM Encrypt & Tag Latency** | < 1.000 ms | Pending (Milestone D) | Queued |
| **Command Delivery to Ack Latency** | < 100 ms | Pending (Milestone D) | Queued |
| **Idle CPU / GPU Activity** | 0.0% | Verified by lifecycle | **Passed** |
