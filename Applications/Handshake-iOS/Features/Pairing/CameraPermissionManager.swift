import Foundation
import AVFoundation
import UIKit

/// Manages camera authorization lifecycle for QR code scanning.
/// Observes AVAuthorizationStatus across all 4 system states (.notDetermined, .authorized, .denied, .restricted)
/// and handles asynchronous authorization requests and navigation to iOS Settings.
@MainActor
public final class CameraPermissionManager: ObservableObject {
    @Published public private(set) var status: AVAuthorizationStatus

    public init() {
        self.status = AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Refreshes the authorization status from the system.
    /// Call when the application returns to the foreground from Settings.
    public func refreshStatus() {
        self.status = AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Explicitly requests camera access from the user when status is `.notDetermined`.
    /// Returns `true` if access is authorized, `false` otherwise.
    @discardableResult
    public func requestCameraAccess() async -> Bool {
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        if current == .authorized {
            self.status = .authorized
            return true
        }

        guard current == .notDetermined else {
            self.status = current
            return false
        }

        let granted = await AVCaptureDevice.requestAccess(for: .video)
        self.status = granted ? .authorized : .denied
        return granted
    }

    /// Opens the iOS Settings application directly to Handshake's permission pane.
    public func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else {
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
