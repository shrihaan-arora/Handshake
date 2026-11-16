import SwiftUI
import AVFoundation
import UIKit

/// Native UIView hosting AVCaptureVideoPreviewLayer as an explicitly managed sublayer.
/// Guarantees that previewLayer bounds, orientation, and session synchronization are maintained
/// across UIKit layout passes, window attachment, and SwiftUI view hierarchy updates.
public final class CameraPreviewView: UIView {
    public let previewLayer: AVCaptureVideoPreviewLayer

    public init(session: AVCaptureSession) {
        self.previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        setupView()
    }

    public override init(frame: CGRect) {
        self.previewLayer = AVCaptureVideoPreviewLayer(session: CameraManager.shared.captureSession)
        super.init(frame: frame)
        setupView()
    }

    public required init?(coder: NSCoder) {
        self.previewLayer = AVCaptureVideoPreviewLayer(session: CameraManager.shared.captureSession)
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(previewLayer)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionDidStartRunning),
            name: .AVCaptureSessionDidStartRunning,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleSessionDidStartRunning() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.previewLayer.frame = self.bounds
            CATransaction.commit()
            self.updateOrientation()
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
        updateOrientation()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
            updateOrientation()
        }
    }

    /// Safely binds or updates the AVCaptureSession on the preview layer.
    public func bindSession(_ session: AVCaptureSession) {
        if previewLayer.session !== session {
            previewLayer.session = session
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
        updateOrientation()
    }

    /// Updates video orientation matching device interface, ensuring the connection is active and properly oriented.
    public func updateOrientation() {
        guard let connection = previewLayer.connection else { return }

        #if os(iOS)
        if connection.isVideoOrientationSupported {
            let orientation = window?.windowScene?.interfaceOrientation ?? .portrait
            let targetOrientation: AVCaptureVideoOrientation
            switch orientation {
            case .landscapeLeft:
                targetOrientation = .landscapeLeft
            case .landscapeRight:
                targetOrientation = .landscapeRight
            case .portraitUpsideDown:
                targetOrientation = .portraitUpsideDown
            default:
                targetOrientation = .portrait
            }

            if connection.videoOrientation != targetOrientation {
                connection.videoOrientation = targetOrientation
            }
        }

        if !connection.isEnabled {
            connection.isEnabled = true
        }
        #endif
    }
}

/// SwiftUI wrapper for high-reliability native camera preview and QR scanning.
/// Interfaces with CameraManager to ensure safe background thread execution and proper lifecycle teardown.
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
        let manager = CameraManager.shared
        let previewView = CameraPreviewView(session: manager.captureSession)

        manager.onCodeScanned = onCodeScanned
        manager.onError = onError
        manager.isScanningActive = isScanningActive

        // Start session asynchronously on dedicated serial queue
        manager.startSession()

        return previewView
    }

    public func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        let manager = CameraManager.shared
        manager.isScanningActive = isScanningActive
        manager.onCodeScanned = onCodeScanned
        manager.onError = onError
        manager.setTorch(on: isTorchOn)

        uiView.bindSession(manager.captureSession)
        if !manager.captureSession.isRunning && isScanningActive {
            manager.startSession()
        }
        uiView.updateOrientation()
    }

    public static func dismantleUIView(_ uiView: CameraPreviewView, coordinator: ()) {
        CameraManager.shared.stopSession()
    }
}
