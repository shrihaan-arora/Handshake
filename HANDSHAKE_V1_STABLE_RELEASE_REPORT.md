# Handshake V1 Stable Release Report

**Release status:** Stable source freeze complete

**Stable source commit:** `4d577dab66ea21d87f370fafd7dfa3e79c1be2bd`

**Release branch:** `codex/handshake-v1-stable`

**Base revision:** `48268b3`
**Freeze date:** 2026-11-20 (Asia/Kolkata)

## Scope frozen

This commit contains only the reviewed V1 implementation, test, and verification-script changes:

- Trust-record lifecycle repair: full public-key identity matching, deterministic active-record selection, duplicate-active consolidation to non-authorizing `SUPERSEDED` history, and durable revocation semantics.
- Atomic Keychain update behavior and fail-closed PSK handling.
- Authenticated local TCP and Bluetooth LE command transport, including replay protections, session authentication, signed acknowledgements, and signed Sleep receipts.
- IOKit-only Sleep Mac request execution. The application distinguishes request acceptance/issuance from independently observing physical sleep.
- iPhone and Mac dashboard support for the dual transport and trust status.
- Regression, adversarial, BLE framing/transport, trust-store, and security-remediation coverage.

The source freeze changes 33 files: 3,910 insertions and 523 deletions. No unrelated reports, PDFs, generated output, Keychain data, private keys, PSKs, provisioning material, or device data are in the source commit.

## Build identity

| Artifact | Bundle identifier | Version | Build | Result |
| --- | --- | --- | --- | --- |
| Handshake macOS | `com.shrihaan.handshake.mac` | 1.0.0 | 1 | Debug build succeeded |
| Handshake iOS | `com.shrihaan.handshake.ios` | 1.0.0 | 1 | Debug-iphoneos build succeeded |
| Core protocol | Handshake V1 | 1.0 | — | Included in both builds |

Both targets were rebuilt from the frozen tree with Xcode on 2026-11-20. The iOS build emitted one non-blocking existing project warning that all interface orientations must be supported unless the app requires full screen.

## Regression and security verification

`swift test --package-path Packages/HandshakeCore` completed successfully after the freeze review. Covered suites include adversarial network behavior, BLE transport/framing, benchmarks, command pipeline, trust-store lifecycle, cryptographic-negative behavior, database integrity, deterministic fuzzing, and the added security-remediation suite.

The end-to-end local TCP benchmark passed its thresholds:

- median: 65.83 ms (limit: 100 ms)
- p95: 68.61 ms (limit: 150 ms)

Security-specific checks include revoked-device rejection, active-over-revoked identity selection, legacy duplicate consolidation, missing/invalid PSK fail-closed behavior, replayed session/command rejection, ECDSA and AEAD tamper rejection, SAS non-disclosure on the wire, signed-receipt validation, and strict capability authorization.

## Physical acceptance evidence

The physical acceptance outcome below is based on the user-confirmed execution on the iPhone 16e and MacBook Air M4, plus the current Mac SQLite audit evidence. The application does not claim to independently observe the operating system entering sleep; `sleep_request_issued` means the authenticated request reached IOKit successfully.

| Transport | Result | Evidence |
| --- | --- | --- |
| Wi-Fi / TCP | PASS — physical Sleep Mac confirmed by user | SQLite accepted Sleep records `FF418C86-D850-475E-A7A1-5C9849EFBC78` (2026-11-19T20:43:54.217Z) and `AF9266B8-FE69-40D2-AF4B-717C3AC0932C` (2026-11-19T20:44:06.910Z), each completed as `sleep_request_issued` / `SLEEP_REQUEST_ISSUED`; their sessions closed normally. The database schema does not persist a transport field for those TCP session rows. |
| Bluetooth LE | PASS — physical Sleep Mac confirmed by user | SQLite shows `active_ble` sessions at 2026-11-19T20:45:50.318Z and 20:46:17.024Z and accepted Sleep records `91EA6F1F-E5BD-4059-89EB-052BD1D43C02` and `CF7717EE-D19D-4B9D-B804-5F73A34D4193`, both completed as `sleep_request_issued` / `SLEEP_REQUEST_ISSUED`. |

Historical revoked identity records remain rejected by the trust-store tests and are not reactivated by this release. The repair selects the sole active record for the same exact full public key; superseded and revoked history remains non-authorizing.

## Recoverable known-good artifacts

Fresh Debug build archives are deliberately local and untracked, preserving the freeze without publishing signed app artifacts or provisioning data:

| Archive | SHA-256 |
| --- | --- |
| `output/stable/4d577dab66ea21d87f370fafd7dfa3e79c1be2bd/Handshake-macOS-Debug.app.zip` | `a343ed838274709a63a74af32e4a84f9ed1f948bc936e5dda678302cc10155ab` |
| `output/stable/4d577dab66ea21d87f370fafd7dfa3e79c1be2bd/Handshake-iOS-Debug-iphoneos.app.zip` | `1c6625dd5e1da489bb7bf906f1c67dc181841e94e67cf37fb4d675213a00bbb8` |

Rebuilding commit `4d577dab66ea21d87f370fafd7dfa3e79c1be2bd` recreates the source-equivalent V1 build. Existing Keychain identities and the trust database were not deleted or modified as part of this freeze.

## Release hygiene

- `git diff --check` passed before commit.
- A focused credential/private-key scan found no committed credentials or PEM/private-key blocks.
- All historical reports, PDFs, generated output, and unrelated untracked files were excluded.
- `main` was not modified; no force-push was used.

## Remaining notes

This is a functional V1 freeze, not a claim that all future test environments or physical configurations are identical. Physical sleep confirmation remains a user-observed event because the host can lose connectivity as it sleeps. The SQLite audit durably records authenticated request acceptance and IOKit request issuance, not an inferred physical-sleep observation.
