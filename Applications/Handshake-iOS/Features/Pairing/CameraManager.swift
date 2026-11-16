import Foundation
import AVFoundation
import UIKit

/// Privacy-preserving, non-blocking telemetry model for camera session diagnostics.
public struct CameraTelemetry: Sendable, CustomStringConvertible {
    public var state: String = "unconfigured"
    public var deviceName: String = "none"
    public var devicePosition: String = "none"
    public var activeFormat: String = "none"
    public var hasInput: Bool = false
    public var hasMetadataOutput: Bool = false
    public var hasVideoOutput: Bool = false
    public var frameCount: UInt64 = 0
    public var firstFrameReceivedAt: Date? = nil
    public var lastFrameReceivedAt: Date? = nil
    public var lastInterruptionReason: String? = nil
    public var lastErrorMessage: String? = nil

    public var description: String {
        """
        [CameraTelemetry] State: \(state), Device: \(deviceName) (\(devicePosition)), Format: \(activeFormat), Inputs: \(hasInput), Metadata: \(hasMetadataOutput), VideoData: \(hasVideoOutput), Frames: \(frameCount), FirstFrame: \(String(describing: firstFrameReceivedAt)), LastFrame: \(String(describing: lastFrameReceivedAt)), Interruption: \(lastInterruptionReason ?? "None"), Error: \(lastErrorMessage ?? "None")
        """
    }
}

public extension Notification.Name {
    static let cameraSessionDidStartRunning = Notification.Name("com.handshake.camera.sessionDidStartRunning")
    static let cameraSessionStateChanged = Notification.Name("com.handshake.camera.sessionStateChanged")
}

/// High-reliability AVFoundation Camera & QR Scanning Manager for iOS.
/// Manages the full capture session lifecycle, hardware device discovery, preview layer binding,
/// metadata output parsing, video frame delivery telemetry, torch control, orientation handling, and error reporting.
/// All capture session operations run exclusively on a dedicated background serial queue.
public final class CameraManager: NSObject, AVCaptureMetadataOutputObjectsDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
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

    // MARK: - Telemetry
    private let telemetryLock = NSLock()
    private var _telemetry = CameraTelemetry()
    public var currentTelemetry: CameraTelemetry {
        telemetryLock.lock()
        defer { telemetryLock.unlock() }
        return _telemetry
    }

    // MARK: - Dedicated Queues
    public let sessionQueue = DispatchQueue(label: "com.handshake.camera.session", qos: .userInitiated)
    private let metadataQueue = DispatchQueue(label: "com.handshake.camera.metadata", qos: .userInteractive)
    private let videoDataQueue = DispatchQueue(label: "com.handshake.camera.videodata", qos: .utility)

    // MARK: - Capture Components
    public let captureSession = AVCaptureSession()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var videoDataOutput: AVCaptureVideoDataOutput?
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

        telemetryLock.lock()
        _telemetry.state = "interrupted: \(reasonStr)"
        _telemetry.lastInterruptionReason = reasonStr
        state = .interrupted(reasonStr)
        telemetryLock.unlock()

        print("[CameraTelemetry] Session interrupted: \(reasonStr)")
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        print("[CameraTelemetry] Session interruption ended. Resuming pipeline...")
        telemetryLock.lock()
        _telemetry.lastInterruptionReason = nil
        _telemetry.state = "resuming"
        telemetryLock.unlock()

        if isScanningActive {
            startSession()
        }
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        let errDesc = "\(error.localizedDescription) (code: \(error.code.rawValue))"
        print("[CameraTelemetry] Capture session runtime error: \(errDesc)")

        telemetryLock.lock()
        _telemetry.lastErrorMessage = errDesc
        _telemetry.state = "failed: \(errDesc)"
        state = .failed(error.localizedDescription)
        telemetryLock.unlock()

        if error.code == .mediaServicesWereReset {
            print("[CameraTelemetry] Media services were reset by system. Re-initializing capture hardware...")
            sessionQueue.async { [weak self] in
                guard let self = self else { return }
                self.videoDeviceInput = nil
                self.metadataOutput = nil
                self.videoDataOutput = nil
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

            self.telemetryLock.lock()
            self._telemetry.state = "configuring"
            self.state = .configuring
            self.telemetryLock.unlock()

            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                let errorMsg = "Camera access is not authorized. Please grant camera permission in iPhone Settings."
                self.telemetryLock.lock()
                self._telemetry.state = "failed: unauthorized"
                self._telemetry.lastErrorMessage = errorMsg
                self.state = .failed(errorMsg)
                self.telemetryLock.unlock()
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
                self.telemetryLock.lock()
                self._telemetry.state = "failed: no camera"
                self._telemetry.lastErrorMessage = errorMsg
                self.state = .failed(errorMsg)
                self.telemetryLock.unlock()
                self.dispatchError(errorMsg)
                completion?(.failure(NSError(domain: "com.handshake.camera", code: 2, userInfo: [NSLocalizedDescriptionKey: errorMsg])))
                return
            }
            self.backCameraDevice = camera

            let dimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
            self.telemetryLock.lock()
            self._telemetry.deviceName = camera.localizedName
            self._telemetry.devicePosition = "back"
            self._telemetry.activeFormat = "\(dimensions.width)x\(dimensions.height)"
            self.telemetryLock.unlock()

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
                    self.telemetryLock.lock()
                    self._telemetry.hasInput = true
                    self.telemetryLock.unlock()
                } else {
                    self.captureSession.commitConfiguration()
                    let errorMsg = "Unable to attach camera input to capture session."
                    self.telemetryLock.lock()
                    self._telemetry.state = "failed: input attachment"
                    self._telemetry.lastErrorMessage = errorMsg
                    self.state = .failed(errorMsg)
                    self.telemetryLock.unlock()
                    self.dispatchError(errorMsg)
                    completion?(.failure(NSError(domain: "com.handshake.camera", code: 3, userInfo: [NSLocalizedDescriptionKey: errorMsg])))
                    return
                }
            } catch {
                self.captureSession.commitConfiguration()
                let errorMsg = "Camera hardware input error: \(error.localizedDescription)"
                self.telemetryLock.lock()
                self._telemetry.state = "failed: \(error.localizedDescription)"
                self._telemetry.lastErrorMessage = errorMsg
                self.state = .failed(errorMsg)
                self.telemetryLock.unlock()
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
                self.telemetryLock.lock()
                self._telemetry.hasMetadataOutput = true
                self.telemetryLock.unlock()
            } else {
                self.captureSession.commitConfiguration()
                let errorMsg = "Unable to attach metadata output for QR scanning."
                self.telemetryLock.lock()
                self._telemetry.state = "failed: metadata attachment"
                self._telemetry.lastErrorMessage = errorMsg
                self.state = .failed(errorMsg)
                self.telemetryLock.unlock()
                self.dispatchError(errorMsg)
                completion?(.failure(NSError(domain: "com.handshake.camera", code: 4, userInfo: [NSLocalizedDescriptionKey: errorMsg])))
                return
            }

            // 6. Attach video data output for non-blocking frame arrival telemetry
            let vDataOutput = AVCaptureVideoDataOutput()
            vDataOutput.alwaysDiscardsLateVideoFrames = true
            vDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            ]
            if let existingVideoOutput = self.videoDataOutput {
                self.captureSession.removeOutput(existingVideoOutput)
            }
            if self.captureSession.canAddOutput(vDataOutput) {
                self.captureSession.addOutput(vDataOutput)
                vDataOutput.setSampleBufferDelegate(self, queue: self.videoDataQueue)
                self.videoDataOutput = vDataOutput
                self.telemetryLock.lock()
                self._telemetry.hasVideoOutput = true
                self.telemetryLock.unlock()
            }

            self.captureSession.commitConfiguration()

            // Verify .qr metadata type availability after configuration commitment
            if let meta = self.metadataOutput, meta.metadataObjectTypes.isEmpty && meta.availableMetadataObjectTypes.contains(.qr) {
                meta.metadataObjectTypes = [.qr]
            }

            self.telemetryLock.lock()
            self._telemetry.state = "configured"
            self.state = .configured
            self.telemetryLock.unlock()

            print("[CameraTelemetry] Capture session configured successfully: \(self.currentTelemetry)")
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
                self.telemetryLock.lock()
                self.state = .running
                self._telemetry.state = "running"
                self.telemetryLock.unlock()
                NotificationCenter.default.post(name: .cameraSessionDidStartRunning, object: nil)
                return
            }

            self.captureSession.startRunning()
            self.telemetryLock.lock()
            self.state = .running
            self._telemetry.state = "running"
            self.telemetryLock.unlock()

            // Ensure metadataObjectTypes is configured once running
            if let meta = self.metadataOutput, meta.metadataObjectTypes.isEmpty && meta.availableMetadataObjectTypes.contains(.qr) {
                meta.metadataObjectTypes = [.qr]
            }

            NotificationCenter.default.post(name: .cameraSessionDidStartRunning, object: nil)
            print("[CameraTelemetry] Camera session started running.")
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
            self.telemetryLock.lock()
            self.state = .stopped
            self._telemetry.state = "stopped"
            self.telemetryLock.unlock()
            print("[CameraTelemetry] Camera session stopped.")
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

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (Frame Telemetry)

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Non-blocking telemetry only. Do not write photos or frames to disk.
        let now = Date()
        telemetryLock.lock()
        _telemetry.frameCount &+= 1
        let count = _telemetry.frameCount
        if _telemetry.firstFrameReceivedAt == nil {
            _telemetry.firstFrameReceivedAt = now
        }
        _telemetry.lastFrameReceivedAt = now
        telemetryLock.unlock()

        if count == 1 {
            print("[CameraTelemetry] First hardware video frame arrived at \(now). Hardware pipeline is actively streaming.")
        } else if count % 150 == 0 {
            print("[CameraTelemetry] Heartbeat: \(count) video frames delivered from \(_telemetry.deviceName).")
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
