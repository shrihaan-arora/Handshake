import SwiftUI
import AVFoundation
import UIKit

/// Native UIView hosting AVCaptureVideoPreviewLayer as its root CoreAnimation layer class.
/// Guarantees that the camera video preview layer bounds and layout are automatically kept
/// in 100% lockstep with UIKit and SwiftUI layout passes without manual frame synchronization.
public final class CameraPreviewView: UIView {
    public override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }

    public var previewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
    }
}

/// High-reliability AVFoundation QR code camera scanner.
/// Configures AVCaptureSession on a background serial queue, isolates metadata callbacks,
/// manages preview layer layout via CameraPreviewView, and provides torch/flashlight control and haptic feedback.
public struct QRScannerView: UIViewRepresentable {
    public let isScanningActive: Bool
    public let isTorchOn: Bool
    public let onCodeScanned: @MainActor (String) -> Void
    public let onError: @MainActor (String) -> Void

    public init(
        isScanningActive: Bool = true,
        isTorchOn: Bool = false,
        onCodeScanned: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.isScanningActive = isScanningActive
        self.isTorchOn = isTorchOn
        self.onCodeScanned = onCodeScanned
        self.onError = onError
    }

    public func makeUIView(context: Context) -> CameraPreviewView {
        let previewView = CameraPreviewView()
        context.coordinator.setupSession(previewView: previewView)
        return previewView
    }

    public func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        context.coordinator.isScanningActive = isScanningActive
        context.coordinator.setTorch(on: isTorchOn)
        context.coordinator.updateOrientation(previewView: uiView)
    }

    public static func dismantleUIView(_ uiView: CameraPreviewView, coordinator: Coordinator) {
        coordinator.stopSession()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            onCodeScanned: onCodeScanned,
            onError: onError
        )
    }

    public final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        public var isScanningActive: Bool = true
        private let onCodeScanned: @MainActor (String) -> Void
        private let onError: @MainActor (String) -> Void

        private let captureSession = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "com.handshake.camera.session", qos: .userInitiated)
        private let metadataQueue = DispatchQueue(label: "com.handshake.camera.metadata", qos: .userInteractive)

        private var backCameraDevice: AVCaptureDevice?
        private var isConfigured = false
        private var lastScannedCode: String?
        private var lastScannedTimestamp: Date = .distantPast
        private weak var activePreviewView: CameraPreviewView?

        init(
            onCodeScanned: @escaping @MainActor (String) -> Void,
            onError: @escaping @MainActor (String) -> Void
        ) {
            self.onCodeScanned = onCodeScanned
            self.onError = onError
            super.init()
        }

        public func setupSession(previewView: CameraPreviewView) {
            self.activePreviewView = previewView

            // Bind session to preview layer immediately
            previewView.previewLayer.session = captureSession
            previewView.previewLayer.videoGravity = .resizeAspectFill

            sessionQueue.async { [weak self] in
                guard let self = self else { return }
                guard !self.isConfigured else {
                    if !self.captureSession.isRunning {
                        self.captureSession.startRunning()
                    }
                    return
                }

                guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                    DispatchQueue.main.async {
                        self.onError("Camera access is not authorized.")
                    }
                    return
                }

                self.captureSession.beginConfiguration()
                if self.captureSession.canSetSessionPreset(.high) {
                    self.captureSession.sessionPreset = .high
                }

                // 1. Discover physical back camera
                let discovery = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [
                        .builtInTripleCamera,
                        .builtInDualWideCamera,
                        .builtInDualCamera,
                        .builtInWideAngleCamera
                    ],
                    mediaType: .video,
                    position: .back
                )

                let device = discovery.devices.first
                    ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(for: .video)

                guard let camera = device else {
                    self.captureSession.commitConfiguration()
                    DispatchQueue.main.async {
                        self.onError("No back camera available on this device.")
                    }
                    return
                }
                self.backCameraDevice = camera

                // 2. Add device input
                do {
                    let input = try AVCaptureDeviceInput(device: camera)
                    if self.captureSession.canAddInput(input) {
                        self.captureSession.addInput(input)
                    } else {
                        self.captureSession.commitConfiguration()
                        DispatchQueue.main.async {
                            self.onError("Unable to attach camera input to capture session.")
                        }
                        return
                    }
                } catch {
                    self.captureSession.commitConfiguration()
                    DispatchQueue.main.async {
                        self.onError("Camera configuration error: \(error.localizedDescription)")
                    }
                    return
                }

                // 3. Add QR metadata output
                let metadataOutput = AVCaptureMetadataOutput()
                if self.captureSession.canAddOutput(metadataOutput) {
                    self.captureSession.addOutput(metadataOutput)
                    metadataOutput.setMetadataObjectsDelegate(self, queue: self.metadataQueue)
                } else {
                    self.captureSession.commitConfiguration()
                    DispatchQueue.main.async {
                        self.onError("Unable to attach metadata output to capture session.")
                    }
                    return
                }

                // Commit session configuration
                self.captureSession.commitConfiguration()
                self.isConfigured = true

                // Configure metadata types AFTER commitConfiguration guarantees availability
                if metadataOutput.availableMetadataObjectTypes.contains(.qr) {
                    metadataOutput.metadataObjectTypes = [.qr]
                }

                // Update orientation on main thread
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, let pv = self.activePreviewView else { return }
                    self.updateOrientation(previewView: pv)
                }

                // Start running session
                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }

                // Re-verify metadataObjectTypes once session is actively running
                if metadataOutput.metadataObjectTypes.isEmpty && metadataOutput.availableMetadataObjectTypes.contains(.qr) {
                    metadataOutput.metadataObjectTypes = [.qr]
                }
            }
        }

        public func updateOrientation(previewView: CameraPreviewView) {
            guard let connection = previewView.previewLayer.connection, connection.isVideoOrientationSupported else { return }
            #if os(iOS)
            let orientation = previewView.window?.windowScene?.interfaceOrientation ?? .portrait
            switch orientation {
            case .landscapeLeft:
                connection.videoOrientation = .landscapeLeft
            case .landscapeRight:
                connection.videoOrientation = .landscapeRight
            case .portraitUpsideDown:
                connection.videoOrientation = .portraitUpsideDown
            default:
                connection.videoOrientation = .portrait
            }
            #endif
        }

        public func setTorch(on: Bool) {
            guard let device = backCameraDevice, device.hasTorch else { return }
            sessionQueue.async {
                do {
                    try device.lockForConfiguration()
                    if on && device.isTorchModeSupported(.on) {
                        device.torchMode = .on
                    } else if !on && device.isTorchModeSupported(.off) {
                        device.torchMode = .off
                    }
                    device.unlockForConfiguration()
                } catch {
                    // Torch configuration failed silently
                }
            }
        }

        public func stopSession() {
            sessionQueue.async { [weak self] in
                guard let self = self else { return }
                if self.captureSession.isRunning {
                    self.captureSession.stopRunning()
                }
            }
        }

        deinit {
            let session = captureSession
            sessionQueue.async {
                if session.isRunning {
                    session.stopRunning()
                }
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

            // Debounce repeated scans within 1.5 seconds
            let now = Date()
            if stringValue == lastScannedCode && now.timeIntervalSince(lastScannedTimestamp) < 1.5 {
                return
            }
            lastScannedCode = stringValue
            lastScannedTimestamp = now

            // Haptic feedback
            DispatchQueue.main.async {
                let feedback = UINotificationFeedbackGenerator()
                feedback.prepare()
                feedback.notificationOccurred(.success)
            }

            Task { @MainActor in
                self.onCodeScanned(stringValue)
            }
        }
    }
}
