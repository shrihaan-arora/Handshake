# HANDSHAKE — V1 Final Acceptance Report

**Branch:** `marathon/handshake-v1`  
**Last Updated:** 2026-11-15  

---

## Final Acceptance Criteria Checklist (18 Criteria)

| # | Acceptance Criterion | Verification Method | Status |
| :---: | :--- | :--- | :---: |
| 1 | Both native applications compile | `scripts/verify.sh` dual-target builds | **VERIFIED** |
| 2 | iPhone and Mac can pair using QR | QR generation, camera scanning, ephemeral handshake | **VERIFIED** (Milestone C) |
| 3 | Both devices verify pairing code independently | Independent SAS derivation via HKDF | **VERIFIED** (Milestone C) |
| 4 | Both devices explicitly approve pairing | Bilateral confirmation signature exchange | **VERIFIED** (Milestone C) |
| 5 | Trusted identities survive app restarts | Keychain / Secure Storage persistence | **VERIFIED** (Milestone B) |
| 6 | Wi-Fi discovery works locally | Bonjour `_handshake._tcp` advertisement & browsing | Pending (Milestone D) |
| 7 | Secure communication works | AES-256-GCM + P-256 ECDSA authenticated framing | Pending (Milestone D) |
| 8 | Packet replay is rejected | Monotonic sequence window verification | **VERIFIED** (Core) |
| 9 | Packet tampering is rejected | AEAD authentication tag + AAD validation | **VERIFIED** (Core) |
| 10 | Unpaired devices cannot issue commands | Trust store public identity signature verification | Pending (Milestone D) |
| 11 | Lock Mac command works through approved mechanism | Documented Apple system call / user permission | Pending (Milestone E) |
| 12 | Sleep Mac command works | IOKit `IOPMSleepSystem` / power management | Pending (Milestone F) |
| 13 | Acknowledgements accurately represent execution | Staged receipt -> execution -> verified ack | Pending (Milestone E/F) |
| 14 | No persistent background process is required | Foreground iOS / Window-bound macOS lifecycle | **VERIFIED** (Design) |
| 15 | No unnecessary battery-intensive scanning | Bounded timeouts, resource deallocation | **VERIFIED** (Design) |
| 16 | All tests and both native builds pass | `scripts/verify.sh` continuous verification | **VERIFIED** |
| 17 | Documentation reflects actual implemented capabilities | Continuous documentation synchronization | **VERIFIED** |
| 18 | Outstanding limitations are disclosed | Documented hardware boundaries & simulator caveats | **VERIFIED** |
