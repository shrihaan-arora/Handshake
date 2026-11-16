import Foundation
import AVFoundation
import UIKit

public extension Notification.Name {
    static let cameraSessionDidStartRunning = Notification.Name("com.handshake.camera.sessionDidStartRunning")
}

/// High-reliability AVFoundation Camera & QR Scanning Manager for iOS.
/// Manages the full capture session lifecycle, hardware device discovery, preview layer binding,
/// metadata output parsing, torch control, orientation handling, and error reporting.
/// All capture session operations run exclusively on a dedicated background serial queue.
public final class CameraManager: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    public static let shared = CameraManager()

    // MARK: - State Management
    public enum SessionState: Equatable, Sendable {
        case unconfigured
        case configuring
        case configured
        case running
        case interrupted(String)
        case stopped
        case failed(String)
    }

    public private(set) var state: SessionState = .unconfigured

    // MARK: - Dedicated Queues
    public let sessionQueue = DispatchQueue(label: "com.handshake.camera.session", qos: .userInitiated)
    private let metadataQueue = DispatchQueue(label: "com.handshake.camera.metadata", qos: .userInteractive)

    // MARK: - Capture Components
    public let captureSession = AVCaptureSession()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var backCameraDevice: AVCaptureDevice?

    // MARK: - Scanning Callbacks & Filters
    public var onCodeScanned: (@MainActor (String) -> Void)?
    public var onError: (@MainActor (String) -> Void)?
    public var isScanningActive: Bool = true

    // MARK: - Debouncing & Validation
    private var lastScannedCode: String?
    private var lastScannedTimestamp: Date = .distantPast
    private var currentTorchMode: AVCaptureDevice.TorchMode = .off

    public override init() {
        super.init()
        registerNotificationObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Interruption & Runtime Error Observers

    private func registerNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionWasInterrupted(_:)),
            name: .AVCaptureSessionWasInterrupted,
            object: captureSession
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded(_:)),
            name: .AVCaptureSessionInterruptionEnded,
            object: captureSession
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError(_:)),
            name: .AVCaptureSessionRuntimeError,
            object: captureSession
        )
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        var reasonStr = "Unknown"
        if let reasonValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
           let reason = AVCaptureSession.InterruptionReason(rawValue: reasonValue) {
            switch reason {
            case .videoDeviceNotAvailableInBackground:
                reasonStr = "videoDeviceNotAvailableInBackground"
            case .audioDeviceInUseByAnotherClient:
                reasonStr = "audioDeviceInUseByAnotherClient"
            case .videoDeviceInUseByAnotherClient:
                reasonStr = "videoDeviceInUseByAnotherClient"
            case .videoDeviceNotAvailableWithMultipleForegroundApps:
                reasonStr = "videoDeviceNotAvailableWithMultipleForegroundApps"
            case .videoDeviceNotAvailableDueToSystemPressure:
                reasonStr = "videoDeviceNotAvailableDueToSystemPressure"
            @unknown default:
                reasonStr = "unknown (\(reasonValue))"
            }
        }

        state = .interrupted(reasonStr)
        print("[CameraManager] Session interrupted: \(reasonStr)")
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        print("[CameraManager] Session interruption ended. Resuming pipeline...")
        state = .configured
        if isScanningActive {
            startSession()
        }
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        let errDesc = "\(error.localizedDescription) (code: \(error.code.rawValue))"
        print("[CameraManager] Capture session runtime error: \(errDesc)")

        state = .failed(error.localizedDescription)

        if error.code == .mediaServicesWereReset {
            print("[CameraManager] Media services reset. Re-configuring...")
            sessionQueue.async { [weak self] in
                guard let self = self else { return }
                self.videoDeviceInput = nil
                self.metadataOutput = nil
                self.configureSession { [weak self] result in
                    if case .success = result, let self = self, self.isScanningActive {
                        self.startSession()
                    }
                }
            }
        } else {
            sessionQueue.async { [weak self] in
                guard let self = self, self.isScanningActive else { return }
                self.startSession()
            }
        }
    }

    // MARK: - Session Configuration

    /// Configures the AVCaptureSession on the dedicated serial queue.
    /// Thread-safe and idempotent: prevents duplicate session configuration.
    public func configureSession(completion: (@Sendable (Result<Void, Error>) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            if self.videoDeviceInput != nil && self.metadataOutput != nil && (self.state == .configured || self.state == .running) {
                completion?(.success(()))
                return
            }

            self.state = .configuring

            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                let errorMsg = "Camera access is not authorized. Please grant camera permission in iPhone Settings."
                self.state = .failed(errorMsg)
                self.dispatchError(errorMsg)
                completion?(.failure(NSError(domain: "com.handshake.camera", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMsg])))
                return
            }

            self.captureSession.beginConfiguration()

            // 1. Configure session preset for high-reliability barcode scanning & video preview
            if self.captureSession.canSetSessionPreset(.high) {
                self.captureSession.sessionPreset = .high
            } else if self.captureSession.canSetSessionPreset(.photo) {
                self.captureSession.sessionPreset = .photo
            }

            // 2. Discover physical back camera (iPhone 16/16e compatible)
            let deviceTypes: [AVCaptureDevice.DeviceType] = [
                .builtInWideAngleCamera,
                .builtInDualCamera,
                .builtInTripleCamera,
                .builtInUltraWideCamera
            ]
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: deviceTypes,
                mediaType: .video,
                position: .back
            )
            let device = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
                ?? discovery.devices.first
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video)

            guard let camera = device else {
                self.captureSession.commitConfiguration()
                let errorMsg = "No physical back camera available on this device."
                self.state = .failed(errorMsg)
                self.dispatchError(errorMsg)
                completion?(.failure(NSError(domain: "com.handshake.camera", code: 2, userInfo: [NSLocalizedDescriptionKey: errorMsg])))
                return
            }
            self.backCameraDevice = camera

            // 3. Configure autofocus & autoexposure for fast screen barcode scanning
            do {
                try camera.lockForConfiguration()
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                }
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
                camera.unlockForConfiguration()
            } catch {
                // Focus lock failure is non-fatal
            }

            // 4. Attach video device input
            do {
                if let existing = self.videoDeviceInput {
                    self.captureSession.removeInput(existing)
                }
                let input = try AVCaptureDeviceInput(device: camera)
                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                    self.videoDeviceInput = input
                } else {
                    self.captureSession.commitConfiguration()
                    let errorMsg = "Unable to attach camera input to capture session."
                    self.state = .failed(errorMsg)
                    self.dispatchError(errorMsg)
                    completion?(.failure(NSError(domain: "com.handshake.camera", code: 3, userInfo: [NSLocalizedDescriptionKey: errorMsg])))
                    return
                }
            } catch {
                self.captureSession.commitConfiguration()
                let errorMsg = "Camera hardware input error: \(error.localizedDescription)"
                self.state = .failed(errorMsg)
                self.dispatchError(errorMsg)
                completion?(.failure(error))
                return
            }

            // 5. Attach metadata output for QR codes
            let metaOutput = AVCaptureMetadataOutput()
            if let existingOutput = self.metadataOutput {
                self.captureSession.removeOutput(existingOutput)
            }
            if self.captureSession.canAddOutput(metaOutput) {
                self.captureSession.addOutput(metaOutput)
                metaOutput.setMetadataObjectsDelegate(self, queue: self.metadataQueue)
                if metaOutput.availableMetadataObjectTypes.contains(.qr) {
                    metaOutput.metadataObjectTypes = [.qr]
                }
                self.metadataOutput = metaOutput
            } else {
                self.captureSession.commitConfiguration()
                let errorMsg = "Unable to attach metadata output for QR scanning."
                self.state = .failed(errorMsg)
                self.dispatchError(errorMsg)
                completion?(.failure(NSError(domain: "com.handshake.camera", code: 4, userInfo: [NSLocalizedDescriptionKey: errorMsg])))
                return
            }

            self.captureSession.commitConfiguration()

            // Verify .qr metadata type availability after configuration commitment
            if let meta = self.metadataOutput, meta.metadataObjectTypes.isEmpty && meta.availableMetadataObjectTypes.contains(.qr) {
                meta.metadataObjectTypes = [.qr]
            }

            self.state = .configured
            print("[CameraManager] Capture session configured successfully.")
            completion?(.success(()))
        }
    }

    // MARK: - Lifecycle Management

    /// Starts the capture session on the dedicated background serial queue.
    public func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            // Re-configure if inputs are missing, unconfigured, or recovering from a previous failure
            if self.videoDeviceInput == nil || self.metadataOutput == nil || self.state == .unconfigured {
                self.configureSession { [weak self] result in
                    if case .success = result {
                        self?.startSession()
                    }
                }
                return
            }

            guard !self.captureSession.isRunning else {
                self.state = .running
                NotificationCenter.default.post(name: .cameraSessionDidStartRunning, object: nil)
                return
            }

            self.captureSession.startRunning()
            self.state = .running

            // Ensure metadataObjectTypes is configured once running
            if let meta = self.metadataOutput, meta.metadataObjectTypes.isEmpty && meta.availableMetadataObjectTypes.contains(.qr) {
                meta.metadataObjectTypes = [.qr]
            }

            NotificationCenter.default.post(name: .cameraSessionDidStartRunning, object: nil)
            print("[CameraManager] Camera session started running.")
        }
    }

    /// Stops the capture session on the dedicated background serial queue and turns off torch.
    public func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.setTorchSync(on: false)
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            self.state = .stopped
            print("[CameraManager] Camera session stopped.")
        }
    }

    // MARK: - Torch Control

    /// Toggles the hardware torch, deduplicating requests to prevent flooding the session queue.
    public func setTorch(on: Bool) {
        sessionQueue.async { [weak self] in
            self?.setTorchSync(on: on)
        }
    }

    private func setTorchSync(on: Bool) {
        guard let device = backCameraDevice, device.hasTorch else { return }
        let targetMode: AVCaptureDevice.TorchMode = on ? .on : .off
        guard currentTorchMode != targetMode else { return }

        do {
            try device.lockForConfiguration()
            if on && device.isTorchModeSupported(.on) {
                device.torchMode = .on
                currentTorchMode = .on
            } else if !on && device.isTorchModeSupported(.off) {
                device.torchMode = .off
                currentTorchMode = .off
            }
            device.unlockForConfiguration()
        } catch {
            // Torch adjustment failed silently
        }
    }

    // MARK: - Error Dispatch

    private func dispatchError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    public func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard isScanningActive else { return }
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadataObject.type == .qr,
              let stringValue = metadataObject.stringValue,
              !stringValue.isEmpty else {
            return
        }

        // Validate QR contents before forwarding them
        guard stringValue.hasPrefix("handshake://pair") else {
            // Not a Handshake pairing QR code, ignore non-handshake codes
            return
        }

        // Debounce repeated scans within 1.5 seconds
        let now = Date()
        guard stringValue != lastScannedCode || now.timeIntervalSince(lastScannedTimestamp) > 1.5 else {
            return
        }
        lastScannedCode = stringValue
        lastScannedTimestamp = now

        // Trigger haptic feedback
        DispatchQueue.main.async {
            let feedback = UINotificationFeedbackGenerator()
            feedback.prepare()
            feedback.notificationOccurred(.success)
        }

        // Forward to callback on MainActor
        let scannedCode = stringValue
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isScanningActive else { return }
            self.onCodeScanned?(scannedCode)
        }
    }
}
