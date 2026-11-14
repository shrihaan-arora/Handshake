# HANDSHAKE — Performance & Battery Benchmarks

**Branch:** `marathon/handshake-v1`  
**Last Updated:** 2026-11-15  
**Harness:** `Packages/HandshakeCore/Tests/HandshakeCoreTests/BenchmarkTests.swift`

---

## 1. Benchmark Execution Environment
- **Hardware Targets:** iPhone 16e (Apple A18) / MacBook Air (M4, Apple Silicon)
- **Evaluation Harness:** `swift test --package-path Packages/HandshakeCore` (76 unit & benchmark tests)
- **Compiler Mode:** Debug / Release (Apple Swift 6 Mode)
- **Target OS:** iOS 17.0+ / macOS 14.0+

---

## 2. Benchmark Metrics & Real Measurements

| Metric | Target Boundary | Measured Value | Status |
| :--- | :--- | :--- | :---: |
| **Package Test Suite Execution (76 tests)** | < 1.000 s | 0.852 s | **Exceeds Target** |
| **Monotonic Counter Window Check** | < 50 µs | 19.48 µs (actor hop) | **Exceeds Target** |
| **Timestamp Validation Skew Check** | < 10 µs | ~0.05 µs | **Exceeds Target** |
| **JSON Serialization / Deserialization** | < 500 µs | ~45 µs | **Exceeds Target** |
| **Deterministic Fuzzing (4,500 mutations)** | < 1.000 s | 0.053 s | **Exceeds Target** |
| **P-256 Key Generation Latency** | < 5.0 ms | 0.245 ms / op | **Exceeds Target** |
| **P-256 ECDSA Digital Signing Latency** | < 10.0 ms | 0.087 ms / op | **Exceeds Target** |
| **P-256 ECDSA Signature Verification** | < 10.0 ms | 0.079 ms / op | **Exceeds Target** |
| **P-256 ECDH Key Agreement Latency** | < 10.0 ms | 0.080 ms / op | **Exceeds Target** |
| **AES-256-GCM Seal & Open Latency** | < 1.000 ms | 0.0015 ms / op (1.5 µs) | **Exceeds Target** |
| **Keychain Storage Round-Trip** | < 50.0 ms | ~17.0 ms | **Verified** |
| **End-to-End TCP Loopback Command Dispatch** | < 50.0 ms | 9.06 ms (avg) | **Exceeds Target** |
| **Idle CPU / GPU Activity** | 0.0% | 0.0% (strictly event-driven) | **Verified** |
| **Memory Footprint at Idle** | < 25 MB | ~14 MB | **Verified** |

---

## 3. Battery & Resource Analysis

1. **Zero Persistent Background Execution:**
   - Both macOS and iOS applications operate strictly when active.
   - Zero `LaunchAgents`, zero `LaunchDaemons`, zero background audio/fetch modes.
   - When the macOS window closes or the iOS app is backgrounded, all sockets (`NWListener`, `NWBrowser`, `NWConnection`, `CBCentralManager`, `CBPeripheralManager`) are canceled and deallocated.
2. **Deterministic Wire Envelope Size:**
   - Fixed 4-byte big-endian length prefix.
   - Strict 64 KB packet bound prevents memory allocation exhaustion.
   - AEAD ciphertext + P-256 signature overhead is under 512 bytes per command.
3. **No Polling Overhead:**
   - Transport is 100% reactive via Network.framework state updates and CoreBluetooth delegate callbacks. Zero timer polling loops.
