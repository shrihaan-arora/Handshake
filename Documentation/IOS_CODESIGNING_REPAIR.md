# HANDSHAKE — iOS Code Signing Repair Report

**Date:** 2026-11-15  
**Auditor:** Principal Apple-Platform Software Architect & Application Security Engineer  
**Target Application:** `Handshake-iOS.app` (`com.shrihaan.handshake.ios`)  
**Target Hardware:** iPhone 16e (`iPhone17,5`, UDID: `00008140-00042C3902F2801C`, iOS 27.0 `24A437`)  
**Status:** **REPAIRED & INSTALLED ON PHYSICAL DEVICE**

---

## 1. Actual Root Cause

The physical-device installation failure (`0xe800801c — No code signature found`, `MIInstallerErrorDomain Code: 13`, `LaunchExecutableValidationErrorDomain Code: 1`) was caused by target-level build settings in `Handshake.xcodeproj/project.pbxproj` and `generate_xcodeproj.py`:

```properties
CODE_SIGNING_ALLOWED = NO;
CODE_SIGNING_REQUIRED = NO;
```

These flags had been placed into the project during initial Phase 1 headless development. Even though the user subsequently configured Automatic Signing in the Xcode GUI with their Personal Development Team (`DW8DPY9ALB`), the explicit `CODE_SIGNING_ALLOWED = NO` setting in the project file took precedence during compilation.

### The Mechanism of Failure:
1. When `xcodebuild` compiled `Handshake-iOS`, the build system evaluated `CODE_SIGNING_ALLOWED = NO` and completely omitted the `CodeSign` build phase.
2. The compiler generated a raw Mach-O binary and app bundle in `DerivedData/.../Debug-iphoneos/Handshake-iOS.app`.
3. No `_CodeSignature` directory was created.
4. No `embedded.mobileprovision` file was packaged.
5. The Mach-O binary had zero signature blocks.
6. When Xcode or `devicectl` attempted to install the bundle on the physical iPhone 16e, the on-device iOS MobileInstallation daemon rejected the package with error `0xe800801c` (no code signature found).

---

## 2. Files and Settings Changed

### 1. `Handshake.xcodeproj/project.pbxproj`
- **`PBXProject.attributes.TargetAttributes`**:
  Added explicit Automatic Provisioning metadata for target `D8C49ACFAC9A52B41768650D` (`Handshake-iOS`):
  ```properties
  DevelopmentTeam = DW8DPY9ALB;
  ProvisioningStyle = Automatic;
  ```
- **`XCBuildConfiguration` (Debug `BFF872EB2B0C28D9222BD41D`)**:
  - Removed: `CODE_SIGNING_ALLOWED = NO;`
  - Removed: `CODE_SIGNING_REQUIRED = NO;`
  - Retained: `CODE_SIGN_STYLE = Automatic;`
  - Retained: `CODE_SIGN_IDENTITY = "Apple Development";`
  - Retained: `DEVELOPMENT_TEAM = DW8DPY9ALB;`
- **`XCBuildConfiguration` (Release `29C8CF94EE8726D54FC06E0E`)**:
  - Removed: `CODE_SIGNING_ALLOWED = NO;`
  - Removed: `CODE_SIGNING_REQUIRED = NO;`
  - Retained: `CODE_SIGN_STYLE = Automatic;`
  - Retained: `CODE_SIGN_IDENTITY = "Apple Development";`
  - Retained: `DEVELOPMENT_TEAM = DW8DPY9ALB;`

### 2. `generate_xcodeproj.py`
- Updated the project generator script to mirror the fix, ensuring future project regenerations never reintroduce `CODE_SIGNING_ALLOWED = NO`.

---

## 3. Before-and-After Signing Configuration

| Build Setting | Before Repair | After Repair | Effect |
| :--- | :--- | :--- | :--- |
| **`CODE_SIGNING_ALLOWED`** | `NO` | *(default / `YES`)* | Enables Xcode `CodeSign` build phase |
| **`CODE_SIGNING_REQUIRED`** | `NO` | *(default / `YES`)* | Requires signing for physical device |
| **`CODE_SIGN_STYLE`** | `Automatic` | `Automatic` | Preserved Xcode-managed signing |
| **`CODE_SIGN_IDENTITY`** | `Apple Development` | `Apple Development` | Preserved Apple Development certificate |
| **`DEVELOPMENT_TEAM`** | `DW8DPY9ALB` | `DW8DPY9ALB` | Preserved user Personal Team |
| **`PRODUCT_BUNDLE_IDENTIFIER`** | `com.shrihaan.handshake.ios`| `com.shrihaan.handshake.ios`| Preserved bundle identifier |
| **`TargetAttributes.ProvisioningStyle`**| *(missing)* | `Automatic` | Recognizes team profile mapping |

---

## 4. `codesign` Verification Output

Following a clean build for physical destination `id=00008140-00042C3902F2801C`:

### 4.1 Detailed Signature Inspection (`codesign -dv --verbose=4`):
```text
Executable=/Users/SHREEHANARORA/Library/Developer/Xcode/DerivedData/Handshake-ckokmlywszwrijdicsxhwomkkicw/Build/Products/Debug-iphoneos/Handshake-iOS.app/Handshake-iOS
Identifier=com.shrihaan.handshake.ios
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20400 size=510 flags=0x0(none) hashes=5+7 location=embedded
VersionPlatform=2
VersionMin=1114112
VersionSDK=1769984
Hash type=sha256 size=32
CandidateCDHash sha256=184dd568a461b5a04fcfcd8bd4238245dad16945
CandidateCDHashFull sha256=184dd568a461b5a04fcfcd8bd4238245dad169453deeffb3d1cb1396509ee96a
Hash choices=sha256
CMSDigest=184dd568a461b5a04fcfcd8bd4238245dad169453deeffb3d1cb1396509ee96a
CMSDigestType=2
Executable Segment base=0
Executable Segment limit=49152
Executable Segment flags=0x11
Page size=16384
CDHash=184dd568a461b5a04fcfcd8bd4238245dad16945
Signature size=4783
Authority=Apple Development: 917800967120 (UX2THUQYT3)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
Signed Time=15 Nov 2026 at 7:01:49 AM
Info.plist entries=28
TeamIdentifier=DW8DPY9ALB
Sealed Resources version=2 rules=10 files=3
Internal requirements count=1 size=188
Total signatures=1
Chosen signature=1
```

### 4.2 Deep Strict Verification (`codesign --verify --deep --strict --verbose=2`):
```text
/Users/SHREEHANARORA/Library/Developer/Xcode/DerivedData/Handshake-ckokmlywszwrijdicsxhwomkkicw/Build/Products/Debug-iphoneos/Handshake-iOS.app: valid on disk
/Users/SHREEHANARORA/Library/Developer/Xcode/DerivedData/Handshake-ckokmlywszwrijdicsxhwomkkicw/Build/Products/Debug-iphoneos/Handshake-iOS.app: satisfies its Designated Requirement
```
Exit code: `0`.

---

## 5. Provisioning Profile Verification

The embedded provisioning profile (`embedded.mobileprovision`) was unpacked and verified using `security cms -D -i`:

- **Name:** `iOS Team Provisioning Profile: com.shrihaan.handshake.ios`
- **Profile UUID:** `e4f145e4-039a-48b9-902b-6fdcdc5e92ba`
- **Team Identifier:** `DW8DPY9ALB` (`Shrihaan Arora`)
- **Application Identifier:** `DW8DPY9ALB.com.shrihaan.handshake.ios`
- **Provisioned Device:** `00008140-00042C3902F2801C` (Matches target iPhone 16e hardware UDID)
- **Keychain Access Groups:** `DW8DPY9ALB.*`
- **Developer Certificate:** Matches `Apple Development: 917800967120 (UX2THUQYT3)` in Keychain.

---

## 6. Physical Device Installation Result

Installation was performed directly to the connected iPhone 16e using Apple's official `devicectl`:

```bash
xcrun devicectl device install app \
    --device 00008140-00042C3902F2801C \
    /Users/SHREEHANARORA/Library/Developer/Xcode/DerivedData/Handshake-ckokmlywszwrijdicsxhwomkkicw/Build/Products/Debug-iphoneos/Handshake-iOS.app
```

### Command Output:
```text
App installed:
• bundleID: com.shrihaan.handshake.ios
• installationURL: file:///private/var/containers/Bundle/Application/44BC6502-6624-4D6E-B2E1-E03733071B19/Handshake-iOS.app/
• launchServicesIdentifier: unknown
• databaseUUID: 1CB248AC-4AEE-4B3A-8AB8-339259EC966C
• databaseSequenceNumber: 4312
• options: 
```
**Exit Code:** `0` (**SUCCESS**).  
The app bundle is installed on the physical device filesystem.

---

## 7. Remaining Blocker (User Device Interaction)

When launching the application on the device for the first time via a free Personal Apple ID:

```text
ERROR: The request was denied by service delegate (SBMainWorkspace) for reason: Security 
("Unable to launch com.shrihaan.handshake.ios because it has an invalid code signature, 
inadequate entitlements or its profile has not been explicitly trusted by the user").
```

### One-Time Device Resolution:
This is a standard Apple iOS security requirement for free developer sideloading. To launch the app:
1. On your iPhone 16e screen, open **Settings $\to$ General $\to$ VPN & Device Management**.
2. Under **Developer App**, tap **Shrihaan Arora**.
3. Tap **Trust "Apple Development: 917800967120 (UX2THUQYT3)"** and confirm **Trust**.
4. Tap the **Handshake** icon on your iPhone home screen to launch!
