import SwiftUI
import AVFoundation
import UIKit

/// High-reliability AVFoundation QR code camera scanner.
/// Configures AVCaptureSession on a background serial queue, isolates metadata callbacks,
/// manages preview layer layout, and provides torch/flashlight control and haptic feedback.
public struct QRScannerView: UIViewControllerRepresentable {
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

    public func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    public func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        uiViewController.isScanningActive = isScanningActive
        uiViewController.setTorch(on: isTorchOn)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public final class Coordinator: NSObject, QRScannerViewControllerDelegate {
        private let parent: QRScannerView

        init(parent: QRScannerView) {
            self.parent = parent
        }

        public func qrScannerDidScan(code: String) {
            Task { @MainActor in
                parent.onCodeScanned(code)
            }
        }

        public func qrScannerDidFail(error: String) {
            Task { @MainActor in
                parent.onError(error)
            }
        }
    }
}

public protocol QRScannerViewControllerDelegate: AnyObject {
    func qrScannerDidScan(code: String)
    func qrScannerDidFail(error: String)
}

public final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    public weak var delegate: QRScannerViewControllerDelegate?
    public var isScanningActive: Bool = true

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var backCameraDevice: AVCaptureDevice?
    private let sessionQueue = DispatchQueue(label: "com.handshake.camera.session", qos: .userInitiated)
    private let metadataQueue = DispatchQueue(label: "com.handshake.camera.metadata", qos: .userInteractive)
    private var hasConfiguredSession = false
    private var lastScannedCode: String?
    private var lastScannedTimestamp: Date = .distantPast

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.previewLayer = preview

        sessionQueue.async { [weak self] in
            self?.configureSession()
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        updateVideoOrientation()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [weak self] in
            guard let self = self, self.hasConfiguredSession, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        sessionQueue.async { [weak self] in
            guard let self = self, self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
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

    private func configureSession() {
        guard !hasConfiguredSession else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.qrScannerDidFail(error: "Camera access is not authorized.")
            }
            return
        }

        captureSession.beginConfiguration()

        // 1. Discover physical back camera
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)

        guard let camera = device else {
            captureSession.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.qrScannerDidFail(error: "No physical camera available on this device.")
            }
            return
        }
        self.backCameraDevice = camera

        // 2. Add device input
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            } else {
                captureSession.commitConfiguration()
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.qrScannerDidFail(error: "Unable to add camera input to capture session.")
                }
                return
            }
        } catch {
            captureSession.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.qrScannerDidFail(error: "Camera configuration error: \(error.localizedDescription)")
            }
            return
        }

        // 3. Add QR metadata output
        let metadataOutput = AVCaptureMetadataOutput()
        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: metadataQueue)
            if metadataOutput.availableMetadataObjectTypes.contains(.qr) {
                metadataOutput.metadataObjectTypes = [.qr]
            } else {
                captureSession.commitConfiguration()
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.qrScannerDidFail(error: "QR code detection not supported by hardware.")
                }
                return
            }
        } else {
            captureSession.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.qrScannerDidFail(error: "Unable to add metadata output to capture session.")
            }
            return
        }

        // Commit configuration BEFORE starting session
        captureSession.commitConfiguration()
        hasConfiguredSession = true

        if !captureSession.isRunning {
            captureSession.startRunning()
        }
    }

    private func updateVideoOrientation() {
        guard let connection = previewLayer?.connection, connection.isVideoOrientationSupported else { return }
        #if os(iOS)
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
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

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    public func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard isScanningActive else { return }
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadataObject.type == .qr,
              let stringValue = metadataObject.stringValue else {
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

        delegate?.qrScannerDidScan(code: stringValue)
    }
}
