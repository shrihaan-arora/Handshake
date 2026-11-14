# HANDSHAKE — Lock Screen Security & Grace Period Review

**Document Version:** 1.0  
**Date:** 2026-11-15  
**Component:** `MacLockEngine.swift`, `MacDashboardViewModel.swift`, `MacDashboardView.swift`  
**Classification:** CRITICAL SECURITY REVIEW  
**Status:** IMPLEMENTED & VERIFIED  

---

## 1. Executive Summary

In macOS, starting the system screen saver does not automatically lock the device unless the operating system's authentication policy requires a password immediately. 

If the user has configured:
```
System Settings → Lock Screen → "Require password after screen saver begins or display is turned off"
```
to a delay (such as **5 minutes**, **15 minutes**, or **Never**), waking the display within that window immediately restores the unlocked user session without prompting for a password, Touch ID, or Apple Watch authentication.

Handshake V1 strictly adheres to the principle of **Zero False Security**:
1. Starting the screen saver is **NEVER** assumed to have locked the Mac.
2. The Mac host companion actively inspects the system-wide screen lock grace period via Apple's documented `/usr/sbin/sysadminctl -screenLock status`.
3. If the setting is anything other than `immediate`, the engine **fails closed**, rejects remote lock commands with an explicit failure reason, and presents a persistent setup warning banner in the macOS interface.

---

## 2. macOS Screen Lock Architecture & Grace Period Risks

### 2.1 Screen Saver vs Screen Lock
* **Screen Saver Activation (`tell application "System Events" to start current screen saver`):**  
  Launches the configured screen saver view above the user session window server. While this visually obscures the desktop, the window server session remains active and unlocked until the grace period timer elapses.
* **The Grace Period Window (`GracePeriod`):**  
  Historically governed by `com.apple.screensaver askForPasswordDelay`, modern macOS (macOS 14 Sonoma, macOS 15 Sequoia, and beyond) manages this policy via `MobileKeyBag` and system administration controls (`sysadminctl`). If grace period > 0, an attacker with physical access during the delay can dismiss the screen saver with trackpad/keyboard activity and obtain full administrative desktop access.

### 2.2 System Settings Inspection
The required configuration for secure locking is:
* **Setting:** `Require password after screen saver begins or display is turned off`
* **Required Value:** `Immediately`

---

## 3. Querying & Verifying Screen Lock Policy

### 3.1 Abandoned Approaches (TCC Hardened)
* Querying `security preferences` via AppleScript:
  ```applescript
  tell application "System Events" to get require password to wake of security preferences
  ```
  **Result:** Fails on modern macOS with AppleEvent error `-10000` due to hardened TCC boundaries protecting security preferences from unauthorized automation.

### 3.2 Supported & Reliable Interface (`/usr/sbin/sysadminctl`)
The native system binary `/usr/sbin/sysadminctl -screenLock status` queries the local authentication bag directly without requiring administrative elevation for reading status.

#### Output Profiles:
1. **Immediate (Secure):**
   ```
   2026-11-15 04:57:42.021 sysadminctl[21025:241467] screenLock delay is immediate
   ```
2. **Delayed (Insecure):**
   ```
   2026-11-15 04:57:42.021 sysadminctl[21025:241467] screenLock delay is 300 seconds
   ```
3. **Disabled (Insecure):**
   ```
   2026-11-15 04:57:42.021 sysadminctl[21025:241467] screenLock is off
   ```

---

## 4. Engineering Implementation in `MacLockEngine`

### 4.1 Data Model
```swift
public enum ScreenLockGracePeriod: Sendable, Equatable {
    case immediate
    case delayed(seconds: Int)
    case disabled
    case unverified(String)

    public var isSecure: Bool {
        if case .immediate = self { return true }
        return false
    }
}
```

### 4.2 Multi-Stage Execution Pipeline
```
[Inbound Lock Command]
         │
         ▼
[Step 1: checkScreenLockGracePeriod()]
         │
         ├──> isSecure == false ───> Return .failed("Grace period is not 'Immediately'...")
         │
         ▼ (isSecure == true)
[Step 2: NSAppleScript System Events start screen saver]
         │
         ├──> AppleScript Error ───> Return .failed("Permission denied / error...")
         │
         ▼
[Step 3: verifyScreenSaverActive()]
         │
         ├──> true  ───> Return .confirmedLocked(passwordRequiredImmediately: true)
         └──> false ───> Return .invoked (transitional state)
```

### 4.3 Fail-Closed Enforcement
When `lockDisplay()` detects an insecure grace period, it halts before invoking the screen saver:
```swift
let gracePeriod = checkScreenLockGracePeriod()
guard gracePeriod.isSecure else {
    return .failed(
        "Screen lock grace period is not set to 'Immediately' (\(gracePeriod.description)). " +
        "Starting the screen saver will not lock the Mac. " +
        "Configure System Settings > Lock Screen > 'Require password after screen saver begins' to 'Immediately'."
    )
}
```

The resulting `CommandAcknowledgment` transmitted to the iPhone carries `.failed(...)`, ensuring the iPhone interface alerts the user rather than giving a false assurance of screen lock.

---

## 5. User Interface Warning Banner

When `MacDashboardViewModel` initializes, it queries `MacLockEngine.checkScreenLockGracePeriod()`. If `!gracePeriod.isSecure`, it exposes a published alert:

* **macOS Dashboard Banner (`MacDashboardView.swift`):**
  A high-visibility card with `Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)` detailing:
  > *"Display Lock Grace Period Warning: Screen lock grace period is not set to 'Immediately' (5m delay). Lock commands from paired devices will be rejected to prevent an unauthenticated display. Please configure System Settings > Lock Screen > 'Require password after screen saver begins' to 'Immediately'."*

* **macOS Security Audit Log:**
  Appends an audit warning entry: `"Configuration Warning: Screen lock grace period is 5m delay (Insecure)"`.

---

## 6. Test Verification & Results

The lock engine security architecture is validated through automated test coverage in `SystemEngineTests.swift`:

1. **`testSysadminctlOutputParsing`:**
   - Validates `.immediate` for raw sysadminctl output lines and plain strings.
   - Validates `.delayed(seconds: 300)` and `.delayed(seconds: 5)`.
   - Validates `.disabled` for `"screenLock is off"`.
   - Validates `.unverified` for malformed and empty strings.
2. **`testMacLockEngineRejectsLockWhenGracePeriodNotImmediate`:**
   - Injects mock grace period provider returning `.delayed(seconds: 300)`: verifies `lockDisplay()` fails closed without invoking AppleScript.
   - Injects mock grace period provider returning `.disabled`: verifies `lockDisplay()` fails closed.
3. **`testMacLockEngineExecutionStateSemantics`:**
   - Verifies `.confirmedLocked(passwordRequiredImmediately: true).isSuccess == true`.
   - Verifies `.confirmedLocked(passwordRequiredImmediately: false).isSuccess == false`.

**Host Machine Verification Result:**
- Host: MacBook Air (Apple M4, macOS 27.0 `26A428`)
- Live Query Output: `screenLock delay is immediate`
- Grace Period Status: `immediate` (`isSecure == true`)
- **Status: PASS**
