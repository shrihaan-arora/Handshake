# HANDSHAKE — Adversarial Network Testing Report

**Branch:** `mission/secure-local-communication`  
**Harness:** `Packages/HandshakeCore/Tests/HandshakeCoreTests/AdversarialNetworkTests.swift`  
**Execution Platform:** MacBook Air (Apple M4, Apple Silicon)  
**Status:** **17/17 ADVERSARIAL SCENARIOS VERIFIED PASSING (100%)**

---

## 1. Overview & Threat Vectors

To ensure that Handshake remains secure and resilient under hostile or abnormal network conditions, we implemented a dedicated 17-scenario adversarial network testing framework.

Tests execute against live local loopback sockets (`NWListener` + `NWConnection`) utilizing exact protocol serialization, cryptographic sealing, wire framing, and sequence verification.

All tests utilize safe test doubles for `MacLockEngine` and `MacSleepEngine` (via `MacSleepEngine(customSleepTrigger: { .sleepInitiated })`), completely eliminating any risk of locking or putting the host development machine to sleep during test runs.

---

## 2. Adversarial Test Results Matrix

| # | Test Scenario | Threat Vector / Attack Mechanic | Expected Defense Behavior | Result | Execution Time |
| :---: | :--- | :--- | :--- | :---: | :---: |
| **01** | `test01_UnknownDeviceConnectionFailsClosed` | Unpaired rogue client connects and dispatches commands signed with its unknown key. | Server looks up public key in `TrustStore`, fails closed, returns `.commandRejected("Device is not paired or recognized.")`, and drops socket. | **PASS** | 0.145s |
| **02** | `test02_ReplayedPacketRejectedBySequenceCounter` | Attacker intercepts a valid packet and re-transmits the identical byte sequence over TCP. | First transmission succeeds; second transmission is detected by `SequenceCounter` sliding window, rejected with `.rejected("Replay attack detected")`, fails closed. | **PASS** | 0.140s |
| **03** | `test03_TamperedCiphertextFailsDecryption` | Attacker manipulates bits in `envelope.ciphertextHex` during transit. | AEAD authentication tag verification fails (`decryptionFailed`); server returns `.rejected("Authentication failed")`, fails closed. | **PASS** | 0.124s |
| **04** | `test04_ModifiedAuthTagFailsAEADOpen` | Attacker substitutes or alters the 16-byte Poly1305/GCM authentication tag. | `AES.GCM.open` fails integrity check; server rejects command, fails closed. | **PASS** | 0.131s |
| **05** | `test05_ForgedCommandFailsECDSAVerification` | Attacker spoofs sender public key in envelope header, but signs with an attacker private key. | Envelope ECDSA signature verification fails against sender's pinned public key; server rejects command, fails closed. | **PASS** | 0.156s |
| **06** | `test06_InvalidSignatureSyntaxOrBytes` | Attacker supplies malformed or random hex bytes in `signatureHex`. | Signature parsing or P-256 point validation fails; server rejects command, fails closed. | **PASS** | 0.131s |
| **07** | `test07_ClockSkewExceededRejected` | Attacker replays command timestamped 60 seconds in the past (beyond 30s validity window). | `SecureChannel.open` checks clock skew against reference time, rejects with `clockSkewExceeded`, fails closed. | **PASS** | 0.128s |
| **08** | `test08_OutOfOrderSequenceBeyondWindow` | Attacker injects a sequence number (seq 50) that is far older than the 1,000-frame sliding window (highest seq 2,500). | `SequenceCounter.validateAndAcceptIncoming` detects sequence is older than `highestSeen - 1000`, returns false, server rejects command. | **PASS** | 0.130s |
| **09** | `test09_DuplicateCommandMessageIdHandling` | Attacker generates two packets with distinct sequence numbers but identical command UUIDs. | Protocol handles message IDs cleanly without internal state corruption or race conditions. | **PASS** | 0.149s |
| **10** | `test10_MalformedPacketTruncatedJSONFraming` | Attacker sends a valid 4-byte length prefix claiming 50 bytes, but payload is truncated/corrupt JSON. | Server's `JSONDecoder` throws decoding error; server catches safely and closes socket without crashing or hanging. | **PASS** | 0.234s |
| **11** | `test11_OversizedPacketExceeding64KBLimit` | Attacker sends a 4-byte header claiming 70,000 bytes (exceeds 64 KB memory-exhaustion limit). | `NetworkFraming.receive` throws `frameTooLarge(70000)` before allocating payload buffer; server drops socket immediately. | **PASS** | 0.364s |
| **12** | `test12_PartialPacketAccumulationOverStream` | Network fragmentation splits a valid frame into 15-byte chunks delivered with 10ms jitter. | `NetworkFraming.receiveExactBytes` accumulates fragments over multiple reads, reassembles full frame, executes command successfully. | **PASS** | 1.016s |
| **13** | `test13_InterruptedConnectionSocketClosedMidFrame` | Client sends 4-byte header claiming 100 bytes, sends 5 bytes, and abruptly closes socket. | `receiveExactBytes` handles EOF, throws `connectionClosed`; server terminates cleanly without crash. | **PASS** | 0.263s |
| **14** | `test14_ConnectionTimeoutHandling` | Client attempts connection to a dead/unreachable port (port 5999). | Client connection timeout fires after bounded window, throwing `connectionFailed`, preventing UI hangs. | **PASS** | 5.201s |
| **15** | `test15_MultipleSimultaneousClientsConcurrent` | Two paired clients (iPhone A and iPhone B) dispatch commands simultaneously to the same server. | Both commands execute in parallel without data race or sequence collision (per-peer sequence counter isolation). | **PASS** | 0.233s |
| **16** | `test16_RevokedPairedDeviceRejection` | A previously paired client that has been revoked in the local `TrustStore` attempts connection. | Server inspects `trustRecord.isRevoked`, fails closed, returns `.commandRejected("Device trust has been revoked.")`. | **PASS** | 0.128s |
| **17** | `test17_MultiMessageSessionSequentialExecution` | Client opens a single TCP session (`openSession`) and dispatches multiple commands (`.ping`, `.lockScreen`). | Both commands execute in sequence over the single persistent TCP connection without reconnect overhead. | **PASS** | 0.152s |

---

## 3. Key Security Observations

1. **Fail-Closed Default:** In every scenario involving malformed data, invalid keys, altered ciphertexts, forged signatures, or revoked trust, the server refuses execution and closes the connection cleanly.
2. **Memory Safety:** The 64 KB wire framing boundary strictly limits inbound memory allocations, preventing denial-of-service through unbounded payload delivery.
3. **Stream Resilience:** TCP stream fragmentation and multi-packet accumulation are fully handled without dropping frames or corrupting message state.
4. **Per-Peer Isolation:** Maintaining independent anti-replay windows per paired public key ensures multi-device households operate smoothly without false replay rejections.
