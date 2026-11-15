import SwiftUI
import AVFoundation
import UIKit

/// Native UIView hosting AVCaptureVideoPreviewLayer as its root CoreAnimation layer class.
/// Automatically keeps video preview layer bounds and layout in lockstep with UIKit and SwiftUI layout passes.
public final class CameraPreviewView: UIView {
    public override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }

    public var previewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
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
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        clipsToBounds = true
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        updateOrientation()
    }

    /// Updates video orientation matching device interface, deduplicating assignments to prevent resetting the pipeline.
    public func updateOrientation() {
        guard let connection = previewLayer.connection, connection.isVideoOrientationSupported else { return }
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

        // Bind capture session to the preview layer
        previewView.previewLayer.session = manager.captureSession

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
        uiView.updateOrientation()
    }

    public static func dismantleUIView(_ uiView: CameraPreviewView, coordinator: ()) {
        CameraManager.shared.stopSession()
    }
}
