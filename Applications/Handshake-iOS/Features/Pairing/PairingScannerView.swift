import SwiftUI
import AVFoundation
import HandshakeCore

public struct PairingScannerView: View {
    @Environment(\.dismiss) private var dismiss
    public var viewModel: DashboardViewModel?

    @StateObject private var permissionManager = CameraPermissionManager()
    @State private var isTorchOn: Bool = false
    @State private var isScanningActive: Bool = true
    @State private var currentStep: ScannerStep = .scanning
    @State private var scannerLaserOffset: CGFloat = -100

    public enum ScannerStep {
        case scanning
        case validating
        case connecting(hostName: String)
        case verifyingSAS(invitation: PairingInvitation, sasCode: String, onDecide: @Sendable (Bool) -> Void)
        case success(hostName: String)
        case failed(message: String)
    }

    public init(viewModel: DashboardViewModel? = nil) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()

                switch permissionManager.status {
                case .notDetermined:
                    cameraPermissionRequestView
                case .denied, .restricted:
                    cameraPermissionDeniedView
                case .authorized:
                    authorizedScannerBody
                @unknown default:
                    cameraPermissionDeniedView
                }
            }
            .navigationTitle("Pair New Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                if permissionManager.status == .authorized, case .scanning = currentStep {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isTorchOn.toggle()
                        } label: {
                            Image(systemName: isTorchOn ? "bolt.fill" : "bolt.slash.fill")
                                .foregroundStyle(isTorchOn ? .yellow : .primary)
                        }
                        .accessibilityLabel(isTorchOn ? "Turn flashlight off" : "Turn flashlight on")
                    }
                }
            }
            .onAppear {
                permissionManager.refreshStatus()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                permissionManager.refreshStatus()
            }
        }
    }

    // MARK: - Subviews for Authorization States

    private var cameraPermissionRequestView: some View {
        ScrollView {
            VStack(spacing: HandshakeTheme.Spacing.lg) {
                Spacer(minLength: 30)

                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.tint)
                    .padding()
                    .background(Color.accentColor.opacity(0.1), in: Circle())

                VStack(spacing: HandshakeTheme.Spacing.xs) {
                    Text("Camera Access Required")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Handshake requires camera access to scan the pairing QR code displayed on your Mac.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, HandshakeTheme.Spacing.lg)
                }

                HandshakeCard {
                    VStack(alignment: .leading, spacing: HandshakeTheme.Spacing.xs) {
                        Label("Zero Cloud Guarantee", systemImage: "lock.shield")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Text("The camera is used solely to read the local pairing code. No photos, videos, or optical data ever leave your device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, HandshakeTheme.Spacing.md)

                Button {
                    Task {
                        await permissionManager.requestCameraAccess()
                    }
                } label: {
                    HStack {
                        Image(systemName: "camera.fill")
                        Text("Enable Camera Access")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: HandshakeTheme.Radius.md, style: .continuous))
                    .foregroundStyle(.white)
                }
                .padding(.horizontal, HandshakeTheme.Spacing.md)
                .padding(.top, HandshakeTheme.Spacing.sm)

                Spacer()
            }
            .padding(.vertical, HandshakeTheme.Spacing.md)
        }
    }

    private var cameraPermissionDeniedView: some View {
        ScrollView {
            VStack(spacing: HandshakeTheme.Spacing.lg) {
                Spacer(minLength: 30)

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 60, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding()
                    .background(Color.orange.opacity(0.1), in: Circle())

                VStack(spacing: HandshakeTheme.Spacing.xs) {
                    Text("Camera Access Disabled")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Camera permission was previously denied. To pair with your Mac, Handshake needs permission to scan QR codes.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, HandshakeTheme.Spacing.lg)
                }

                HandshakeCard {
                    VStack(alignment: .leading, spacing: HandshakeTheme.Spacing.xs) {
                        Label("How to enable:", systemImage: "gearshape")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Text("1. Tap the button below to open iPhone Settings.\n2. Locate 'Camera' and switch the toggle to ON.\n3. Return to Handshake to begin scanning.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, HandshakeTheme.Spacing.md)

                Button {
                    permissionManager.openSettings()
                } label: {
                    HStack {
                        Image(systemName: "gear")
                        Text("Open iPhone Settings")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: HandshakeTheme.Radius.md, style: .continuous))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                }
                .padding(.horizontal, HandshakeTheme.Spacing.md)
                .padding(.top, HandshakeTheme.Spacing.sm)

                Spacer()
            }
            .padding(.vertical, HandshakeTheme.Spacing.md)
        }
    }

    // MARK: - Authorized Scanner Body

    @ViewBuilder
    private var authorizedScannerBody: some View {
        switch currentStep {
        case .scanning, .validating:
            VStack(spacing: 0) {
                // Live camera feed with reticle
                ZStack {
                    QRScannerView(
                        isScanningActive: isScanningActive,
                        isTorchOn: isTorchOn,
                        onCodeScanned: handleScannedCode,
                        onError: handleScannerError
                    )
                    .frame(height: 340)
                    .clipped()

                    // Scanning reticle guide overlay
                    reticleOverlay
                }
                .frame(maxWidth: .infinity)
                .background(Color.black)

                // Guidance and security explanation
                ScrollView {
                    VStack(spacing: HandshakeTheme.Spacing.md) {
                        if case .validating = currentStep {
                            HStack(spacing: HandshakeTheme.Spacing.sm) {
                                ProgressView()
                                Text("Validating Pairing Invitation...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, HandshakeTheme.Spacing.md)
                        } else {
                            VStack(spacing: 4) {
                                Text("Scan Mac Companion QR Code")
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                Text("Align the QR code displayed in Handshake on your Mac screen within the frame.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, HandshakeTheme.Spacing.lg)
                            }
                            .padding(.top, HandshakeTheme.Spacing.md)
                        }

                        // Security Protocol Summary
                        HandshakeCard {
                            Label("Secure Mutual Pairing", systemImage: "shield.lefthalf.filled")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("• Out-of-band ephemeral P-256 ECDH key exchange")
                                Text("• Independent Short Authentication String (SAS) derivation")
                                Text("• Bilateral digital signature verification")
                                Text("• Hardware-backed Secure Enclave identity pinning")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, HandshakeTheme.Spacing.md)
                    }
                    .padding(.bottom, HandshakeTheme.Spacing.lg)
                }
            }

        case .connecting(let hostName):
            VStack(spacing: HandshakeTheme.Spacing.lg) {
                Spacer()
                ProgressView()
                    .scaleEffect(1.5)
                VStack(spacing: 4) {
                    Text("Connecting to \(hostName)...")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("Establishing encrypted local transport over Wi-Fi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

        case .verifyingSAS(let invitation, let sasCode, let onDecide):
            sasVerificationView(invitation: invitation, sasCode: sasCode, onDecide: onDecide)

        case .success(let hostName):
            VStack(spacing: HandshakeTheme.Spacing.lg) {
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.green)

                VStack(spacing: 4) {
                    Text("Pairing Complete")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("\(hostName) is now trusted and pinned for direct local control.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, HandshakeTheme.Spacing.lg)
                }

                Button("Done") {
                    dismiss()
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: HandshakeTheme.Radius.md, style: .continuous))
                .foregroundStyle(.white)
                .padding(.horizontal, HandshakeTheme.Spacing.lg)

                Spacer()
            }
            .padding()

        case .failed(let message):
            VStack(spacing: HandshakeTheme.Spacing.lg) {
                Spacer()
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.red)

                VStack(spacing: HandshakeTheme.Spacing.xs) {
                    Text("Pairing Failed")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, HandshakeTheme.Spacing.lg)
                }

                Button {
                    self.isScanningActive = true
                    self.currentStep = .scanning
                } label: {
                    Text("Scan Again")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.primary, in: RoundedRectangle(cornerRadius: HandshakeTheme.Radius.md, style: .continuous))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                }
                .padding(.horizontal, HandshakeTheme.Spacing.lg)

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Reticle Overlay

    private var reticleOverlay: some View {
        ZStack {
            // Semi-transparent cutout guide
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.85), lineWidth: 3)
                .frame(width: 220, height: 220)

            // Animated scanning laser beam
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.clear, Color.accentColor.opacity(0.8), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 216, height: 3)
                .offset(y: scannerLaserOffset)
                .onAppear {
                    withAnimation(
                        .easeInOut(duration: 1.6)
                        .repeatForever(autoreverses: true)
                    ) {
                        scannerLaserOffset = 100
                    }
                }
        }
    }

    // MARK: - SAS Verification View

    private func sasVerificationView(
        invitation: PairingInvitation,
        sasCode: String,
        onDecide: @escaping @Sendable (Bool) -> Void
    ) -> some View {
        ScrollView {
            VStack(spacing: HandshakeTheme.Spacing.lg) {
                Spacer(minLength: 20)

                Image(systemName: "shield.checkered")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)

                VStack(spacing: 4) {
                    Text("Confirm Security Code")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Verify this code matches the verification code displayed on \(invitation.hostIdentity.displayName):")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, HandshakeTheme.Spacing.lg)
                }

                // 6-digit SAS Code Card
                HandshakeCard {
                    VStack(spacing: HandshakeTheme.Spacing.xs) {
                        Text("VERIFICATION CODE (SAS)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .tracking(1.5)
                            .foregroundStyle(.secondary)

                        Text(sasCode)
                            .font(.system(size: 40, weight: .bold, design: .monospaced))
                            .foregroundStyle(.primary)
                            .tracking(3.0)

                        Text("Calculated from mutual ECDH key agreement")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HandshakeTheme.Spacing.sm)
                }
                .padding(.horizontal, HandshakeTheme.Spacing.md)

                // Bilateral Approval Actions
                VStack(spacing: HandshakeTheme.Spacing.sm) {
                    Button {
                        onDecide(true)
                    } label: {
                        Text("Approve & Pair")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.green, in: RoundedRectangle(cornerRadius: HandshakeTheme.Radius.md, style: .continuous))
                            .foregroundStyle(.white)
                    }

                    Button {
                        onDecide(false)
                        dismiss()
                    } label: {
                        Text("Reject")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, HandshakeTheme.Spacing.md)

                Spacer()
            }
            .padding(.vertical, HandshakeTheme.Spacing.md)
        }
    }

    // MARK: - Scan & Pairing Handlers

    private func handleScannedCode(_ code: String) {
        guard isScanningActive else { return }
        isScanningActive = false
        currentStep = .validating

        do {
            let invitation = try PairingInvitation.parse(from: code)
            startPairingProtocol(with: invitation)
        } catch {
            currentStep = .failed(message: error.localizedDescription)
        }
    }

    private func handleScannerError(_ errorMsg: String) {
        currentStep = .failed(message: errorMsg)
    }

    private func startPairingProtocol(with invitation: PairingInvitation) {
        guard let vm = viewModel else {
            currentStep = .failed(message: "View model unavailable.")
            return
        }

        currentStep = .connecting(hostName: invitation.hostIdentity.displayName)

        Task {
            do {
                let record = try await vm.executePairing(invitation: invitation) { derivedSAS in
                    await withCheckedContinuation { continuation in
                        Task { @MainActor in
                            self.currentStep = .verifyingSAS(
                                invitation: invitation,
                                sasCode: derivedSAS
                            ) { approved in
                                continuation.resume(returning: approved)
                            }
                        }
                    }
                }

                await MainActor.run {
                    vm.handlePairingCompleted(record: record)
                    self.currentStep = .success(hostName: invitation.hostIdentity.displayName)
                }
            } catch {
                await MainActor.run {
                    self.currentStep = .failed(message: error.localizedDescription)
                }
            }
        }
    }
}
