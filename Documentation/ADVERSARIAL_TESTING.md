# HANDSHAKE — Adversarial Security Testing Report

**Date:** 2026-11-15  
**Document Version:** 1.0  
**Target Package:** `Packages/HandshakeCore`  
**Evaluation Scope:** Protocol model fuzzing, boundary exhaustion, serialization integrity, anti-replay validation, and exception resilience.  
**Classification:** Internal Security Engineering Document  

---

## 1. Executive Summary

As part of the **Handshake Adversarial Security Testing Sprint**, an automated, adversarial testing framework was constructed to stress-test the `HandshakeCore` protocol engine. The framework subjected all protocol models, serialization formats, anti-replay state machines, and timing primitives to extreme, malformed, and manipulated inputs.

All testing was executed using **100% native Apple frameworks** (`Foundation`, `XCTest`) with zero external dependencies. A total of **51 test cases** and **4,500 deterministic fuzz iterations** were executed with zero test failures and zero compiler warnings.

During this sprint, **5 security weaknesses and runtime crash vectors** were discovered, documented, and patched.

---

## 2. Test Suites and Coverage Matrix

| Test Suite | Purpose | Test Cases | Fuzz Iterations | Result |
| :--- | :--- | :---: | :---: | :---: |
| **MalformedInputTests** | Malformed, truncated, missing-field, oversized, and corrupted JSON payloads across all 10 protocol models | 15 | — | **PASSED** |
| **ReplayAndSequenceTests** | Monotonic counter validation, duplicates, out-of-order packets, window sliding boundaries, overflow saturation, actor concurrency | 6 | — | **PASSED** |
| **SerializationIntegrityTests** | Full encode/decode round trips, associated data (AAD) bit-level sensitivity, wire field alterations, version constraints, timestamp manipulation | 6 | — | **PASSED** |
| **DeterministicFuzzTests** | Deterministic pseudo-random fuzzer testing bit-flips, byte deletion/insertion, structural token injection, and extreme value fuzzing | 3 | 4,500 | **PASSED** |
| **SecurityBoundaryTests** | Invitation lifetime boundaries, clock skew tolerance, invitation single-use consumption, sequence sliding exhaustion | 9 | — | **PASSED** |
| **ProtocolTests** | Command message typing, command metadata, protocol version comparisons | 5 | — | **PASSED** |
| **EnvelopeTests** | AEAD envelope packaging, associated data generation, counter checks | 3 | — | **PASSED** |
| **ModelTests** | Device identity fingerprints, connection state transitions, revocation lifecycle | 4 | — | **PASSED** |
| **TOTAL** | | **51** | **4,500** | **100% PASS** |

---

## 3. Vulnerabilities Discovered and Remediated

### VULN-ADV-01: Arithmetic Overflow Crash in `SequenceCounter` Sliding Window
- **Severity:** High (Denial of Service)
- **Component:** `Packages/HandshakeCore/Sources/HandshakeCore/Utilities/SequenceCounter.swift`
- **Vulnerability Description:**  
  When checking whether an out-of-order sequence number fell within the acceptable sliding window, the counter evaluated:
  ```swift
  if sequenceNumber + replayWindowSize > highestIncomingSequence
  ```
  If an adversary transmitted an envelope with a sequence number near `UInt64.max` (e.g., `UInt64.max - 10`), the addition `sequenceNumber + replayWindowSize` exceeded `UInt64.max`, triggering an arithmetic overflow runtime trap (`Fatal error: Overflow in +`) and crashing the receiving application.
- **Remediation:**  
  Because the enclosing `else` branch guarantees `sequenceNumber <= highestIncomingSequence`, the calculation was refactored into safe subtraction:
  ```swift
  if highestIncomingSequence - sequenceNumber < replayWindowSize
  ```
  This is mathematically equivalent, guarantees non-negative operands, and eliminates integer overflow risk entirely.

---

### VULN-ADV-02: Arithmetic Overflow and Underflow in `HandshakeTime`
- **Severity:** High (Denial of Service)
- **Component:** `Packages/HandshakeCore/Sources/HandshakeCore/Utilities/HandshakeTime.swift`
- **Vulnerability Description:**  
  `HandshakeTime.isTimestampValid(_:)` calculated clock skew by subtracting raw `Int64` timestamps:
  ```swift
  let differenceSeconds = Double(abs(referenceMs - timestampMilliseconds)) / 1000.0
  ```
  If an adversary provided `timestampMilliseconds: Int64.min` or an extreme negative number, `referenceMs - timestampMilliseconds` overflowed `Int64.max`, causing a fatal crash. Furthermore, `abs(Int64.min)` causes an unhandled runtime trap in Swift.
- **Remediation:**  
  Hardened the validator to reject non-positive timestamps (`guard timestampMilliseconds > 0`), employed Swift's `subtractingReportingOverflow`, and explicitly guarded against `Int64.min`.

---

### VULN-ADV-03: Double-to-Int Conversion Crash in `PairingInvitation`
- **Severity:** Medium (Denial of Service / Parsing Fault)
- **Component:** `Packages/HandshakeCore/Sources/HandshakeCore/Models/PairingInvitation.swift`
- **Vulnerability Description:**  
  In `PairingInvitation.qrPayloadString` and `remainingSeconds(at:)`, dates were converted via `Int(expiresAt.timeIntervalSince1970)`. If a malicious or corrupted invitation payload contained extreme epoch dates (e.g., `Date(timeIntervalSince1970: 1e20)` or `Date.distantFuture`), the cast to `Int` failed with:
  `Fatal error: Double value cannot be converted to Int because it is either infinite or out of range`.
- **Remediation:**  
  Added `.isFinite` validation and upper bound checks (`guard remaining < Double(Int.max)`) before casting to `Int`.

---

### VULN-ADV-04: Non-Finite Date Comparison Bypass in `CommandMessage`
- **Severity:** Low (Logic Validation Bypass)
- **Component:** `Packages/HandshakeCore/Sources/HandshakeCore/Protocol/CommandMessage.swift`
- **Vulnerability Description:**  
  `CommandMessage.isExpired(at:)` calculated `let age = date.timeIntervalSince(timestamp)`. Under IEEE-754 semantics, if `timestamp` was initialized with `Date(timeIntervalSince1970: .nan)`, all comparison operators (`>`, `<`) return `false`. As a result, an invalid NaN timestamp was evaluated as NOT expired (`isExpired() == false`).
- **Remediation:**  
  Added `guard age.isFinite else { return true }` to guarantee that non-finite or corrupted timestamps are immediately classified as expired and invalid.

---

### VULN-ADV-05: Outgoing Monotonic Sequence Counter Saturation
- **Severity:** Low (Denial of Service / State Machine Trap)
- **Component:** `Packages/HandshakeCore/Sources/HandshakeCore/Utilities/SequenceCounter.swift`
- **Vulnerability Description:**  
  In `nextOutgoing()`, `outgoingCounter += 1` would trap with arithmetic overflow if a session exceeded `UInt64.max` packets.
- **Remediation:**  
  Added saturation checks (`guard outgoingCounter < UInt64.max else { return UInt64.max }`) to ensure safe state preservation and trigger session re-negotiation.

---

## 4. Deterministic Fuzzing Architecture

To adhere strictly to the **Supply-Chain Security Constitution** (zero third-party dependencies), a custom, reproducible fuzzing engine was built in `DeterministicFuzzTests.swift`:

1. **Deterministic PRNG:**  
   Implemented a 64-bit XorShift algorithm seeded with a fixed constant (`0xDEAD_BEEF_CAFE_1234`). Every execution produces the exact same sequence of mutations across any Mac or CI environment.
2. **Mutation Strategies:**  
   - **Bit-Flipping:** Flips 1 to 5 random bits across valid serialized JSON payloads.
   - **Byte Deletion:** Removes random byte ranges (1 to 32 bytes) to test parser recovery from truncated frames.
   - **Byte Insertion:** Injects arbitrary raw bytes at random offsets to test delimiter and boundary resilience.
   - **Structural Token Injection:** Injects hostile tokens including format strings (`%s%n%@`), null bytes (`\u0000`), integer boundaries (`-9223372036854775809`, `9223372036854775808`), floating-point edge cases (`NaN`, `Infinity`, `1e309`), path traversal strings (`../../etc/passwd`), and 100-level deep JSON array nesting (`[[[[...]]]]`).
   - **Random Garbage:** Generates bounded raw byte buffers (1 to 2048 bytes) representing completely unsanitized network input.
3. **Target Scope:**  
   Exercised across all 10 protocol and domain models (`CommandEnvelope`, `CommandMessage`, `PairingInvitation`, `PairingRequest`, `PairingResponse`, `PairingConfirmation`, `PairingCompletion`, `TrustRecord`, `DeviceIdentity`, `ProtocolVersion`).
4. **Execution Invariant:**  
   Every fuzzed input must either cleanly parse into a validated model or throw a standard `DecodingError` or `CocoaError`. Zero fatal errors, zero crashes, zero infinite loops.

---

## 5. Remaining Weaknesses & Phase 2 Recommendations

1. **Associated Data Canonicalization (AAD Prefixing):**  
   In `CommandEnvelope.associatedDataPayload`, variable-length strings (`senderPublicKeyHex` and `recipientPublicKeyHex`) are concatenated directly:
   ```swift
   if let senderData = senderPublicKeyHex.data(using: .utf8) { buffer.append(senderData) }
   if let recipientData = recipientPublicKeyHex.data(using: .utf8) { buffer.append(recipientData) }
   ```
   *Recommendation for Phase 2:* Prefix each variable-length field in AAD with a 2-byte or 4-byte big-endian length header to prevent theoretical delimiter-shifting collisions.
2. **Wire Framing Length Bounds:**  
   `MalformedInputTests` confirmed that 1 MB strings in parameters parse safely into memory without crashing. However, in production networking (Phase 2), `Network.framework` frames must enforce a strict maximum envelope size (e.g., 64 KB) at the framing layer before decoding to prevent memory exhaustion DoS.
3. **Cryptographic Validation Decoupling:**  
   The current tests validate serialization integrity and data model parsing. In Phase 2, cryptographic verification (AEAD tag check and digital signature check) must execute *prior* to payload deserialization.

---

## 6. Reproduction & Verification Instructions

### Automated Verification Script
Run the project verification harness from the repository root:
```bash
./scripts/verify.sh
```

### Direct SwiftPM Package Test Execution
Run the full 51-test suite directly with verbose output:
```bash
swift test --package-path Packages/HandshakeCore
```

### Compiler-Supported libFuzzer Execution (Reference)
For continuous compiler-instrumented fuzzing with LLVM AddressSanitizer and libFuzzer:
```bash
# Available on Linux / macOS with toolchain libFuzzer support:
swift test --package-path Packages/HandshakeCore --sanitize=address,fuzzer
```
