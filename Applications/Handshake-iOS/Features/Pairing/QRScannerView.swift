import SwiftUI
import AVFoundation
import UIKit

/// Native UIView hosting AVCaptureVideoPreviewLayer directly as its backing root layer.
/// By overriding layerClass, the preview layer is guaranteed to match the view's frame, bounds,
/// and transform without manual sublayer synchronization or race conditions during SwiftUI layout passes.
public final class CameraPreviewView: UIView {
    public override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    public var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        backgroundColor = .clear
        previewLayer.videoGravity = .resizeAspectFill

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionDidStartRunning),
            name: .cameraSessionDidStartRunning,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleSessionDidStartRunning() {
        DispatchQueue.main.async { [weak self] in
            self?.updateOrientation()
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        updateOrientation()
    }

    /// Safely binds or updates the AVCaptureSession on the backing preview layer.
    public func bindSession(_ session: AVCaptureSession) {
        if previewLayer.session !== session {
            previewLayer.session = session
        }
        updateOrientation()
    }

    /// Updates video orientation matching device interface, ensuring the connection is active and properly oriented.
    public func updateOrientation() {
        guard let connection = previewLayer.connection else { return }

        if connection.isVideoOrientationSupported {
            #if os(iOS)
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
            #endif
        }

        if !connection.isEnabled {
            connection.isEnabled = true
        }
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
        let previewView = CameraPreviewView()
        let manager = CameraManager.shared

        manager.onCodeScanned = onCodeScanned
        manager.onError = onError
        manager.isScanningActive = isScanningActive

        // Bind capture session to the backing preview layer
        previewView.bindSession(manager.captureSession)

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
