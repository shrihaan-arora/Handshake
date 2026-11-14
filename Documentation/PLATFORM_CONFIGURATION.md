# HANDSHAKE — Apple Platform Configuration & Permissions Audit

**Specification:** Apple Platform Entitlements, Information Property Lists, and Sandbox Boundaries  
**Status:** Audited & Verified (Principle of Least Privilege Enforced)  
**Target Platforms:** iOS 17.0+, macOS 14.0+

---

## 1. Bundle Identifiers & Deployment Targets

| Attribute | iOS Target (`Handshake-iOS`) | macOS Target (`Handshake-macOS`) |
| :--- | :--- | :--- |
| **Bundle Identifier** | `com.shrihaan.handshake.ios` | `com.shrihaan.handshake.mac` |
| **Marketing Version** | `1.0.0` | `1.0.0` |
| **Build Number** | `1` | `1` |
| **Deployment Target** | iOS 17.0+ | macOS 14.0+ (Sonoma) |
| **SDK** | `iphoneos` / `iphonesimulator` | `macosx` |
| **Architectures** | `arm64`, `x86_64` (Universal Simulator) | `arm64` (Apple Silicon Native) |

---

## 2. Privacy Usage Strings (`Info.plist`)

Apple privacy guidelines mandate explicit, user-facing explanations for protected resources.

### 2.1 iOS Application (`Applications/Handshake-iOS/Resources/Info.plist`)

| Key | Purpose / Justification | Security & Privacy Impact |
| :--- | :--- | :--- |
| `NSCameraUsageDescription` | Required for scanning the Mac host’s dynamic QR pairing invitation. | Restricted strictly to the `PairingScannerView` sheet. Zero image frames or video feeds are recorded or persisted to disk. |
| `NSLocalNetworkUsageDescription` | Required to browse and establish direct peer TLS sockets with the paired Mac over local Wi-Fi. | Local peer discovery only. Network.framework sockets are constrained to local LAN subnets; zero external traffic. |
| `NSBluetoothAlwaysUsageDescription` | Required to discover nearby Bluetooth Low Energy (BLE) advertisements emitted by the Mac companion. | Proximity pairing only. Bluetooth state is scanned only during active discovery/handshake. |
| `NSBonjourServices` | Array declaring `_handshake._tcp`. Required by iOS 14+ for Bonjour mDNS discovery. | Declares exact service type; prevents promiscuous network scanning. |

### 2.2 macOS Application (`Applications/Handshake-macOS/Resources/Info.plist`)

| Key | Purpose / Justification | Security & Privacy Impact |
| :--- | :--- | :--- |
| `NSLocalNetworkUsageDescription` | Required for the host Mac to listen on port 5894 and accept incoming TLS connections from the paired iPhone. | Bound to local network listener; rejects external routing. |
| `NSBluetoothAlwaysUsageDescription` | Required for `CBPeripheralManager` to broadcast the Mac's proximity advertisement during pairing. | Broadcasts only during active pairing invitation window (120s TTL). |
| `NSBonjourServices` | Array declaring `_handshake._tcp` for local service registration. | Permits Bonjour advertising of the secure Handshake service. |

---

## 3. macOS App Sandbox Entitlements (`Handshake-macOS.entitlements`)

The macOS companion runs strictly inside the Apple App Sandbox to minimize host attack surface.

| Entitlement Key | Value | Security Justification |
| :--- | :--- | :--- |
| `com.apple.security.app-sandbox` | `true` | Enforces OS-level kernel sandbox boundary, preventing arbitrary file system access or privilege escalation. |
| `com.apple.security.network.client` | `true` | Allows establishing outbound network sockets to confirm peer connectivity. |
| `com.apple.security.network.server` | `true` | Allows binding `NWListener` to local port 5894 to accept authenticated command envelopes from paired iPhones. |
| `com.apple.security.device.bluetooth` | `true` | Allows CoreBluetooth access for peripheral advertising during out-of-band device pairing. |

### Omitted / Prohibited Entitlements (Least Privilege):
- ❌ `com.apple.security.network.server.incoming-connections` (unrestricted WAN): **Omitted.**
- ❌ `com.apple.security.files.user-selected.read-write`: **Omitted.**
- ❌ `com.apple.security.files.all-files`: **Omitted.**
- ❌ `com.apple.security.device.camera`: **Omitted** (Mac does not capture video).
- ❌ `com.apple.security.device.microphone`: **Omitted.**
- ❌ `com.apple.security.device.usb`: **Omitted.**
