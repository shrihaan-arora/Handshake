import XCTest
@testable import HandshakeCore

final class PairingEngineTests: XCTestCase {

    private let testKeychain = KeychainManager(service: "com.handshake.test.pairing")

    override func tearDown() {
        super.tearDown()
        try? testKeychain.delete(account: "test.host.truststore")
        try? testKeychain.delete(account: "test.client.truststore")
        try? testKeychain.delete(account: "test.host.id.privateKey")
        try? testKeychain.delete(account: "test.host.id.metadata")
        try? testKeychain.delete(account: "test.client.id.privateKey")
        try? testKeychain.delete(account: "test.client.id.metadata")
    }

    // MARK: - 1. Full Bilateral Pairing Handshake (Happy Path)

    func testCompleteMutualPairingHandshake() async throws {
        // 1. Setup Identities
        let hostIdentity = try CryptoIdentity.createNew(
            label: "test.host.id",
            displayName: "MacBook Air M4",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 15.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let clientIdentity = try CryptoIdentity.createNew(
            label: "test.client.id",
            displayName: "iPhone 16e",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "iOS 18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )

        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "test.host.truststore")
        let clientTrustStore = TrustStore(keychain: testKeychain, storageAccount: "test.client.truststore")
        try await hostTrustStore.removeAll()
        try await clientTrustStore.removeAll()

        // 2. Host (Mac) creates pairing invitation (displayed as QR code)
        let hostSession = HostPairingSession(
            hostIdentity: hostIdentity,
            lifetimeSeconds: 120,
            localPort: 5894,
            serviceName: "Handshake-Host"
        )
        let invitation = hostSession.invitation
        XCTAssertFalse(invitation.isExpired())
        XCTAssertGreaterThanOrEqual(invitation.remainingSeconds(), 118)
        XCTAssertLessThanOrEqual(invitation.remainingSeconds(), 120)

        // 3. Client (iPhone) scans QR and initializes client session
        let clientSession = try ClientPairingSession(
            invitation: invitation,
            clientIdentity: clientIdentity
        )

        // 4. Client generates PairingRequest
        let request = await clientSession.createRequest()
        XCTAssertEqual(request.invitationId, invitation.id)
        XCTAssertEqual(request.clientIdentity.publicKeyHex, clientIdentity.identity.publicKeyHex)

        // 5. Host processes PairingRequest
        let (response, hostSAS) = try await hostSession.processRequest(request)
        XCTAssertEqual(response.invitationId, invitation.id)
        XCTAssertEqual(response.hostIdentity.publicKeyHex, hostIdentity.identity.publicKeyHex)
        XCTAssertFalse(response.hostSignatureHex.isEmpty)

        // 6. Client processes PairingResponse and independently derives SAS
        let clientSAS = try await clientSession.processResponse(response)

        // 7. Verify Independent Short Authentication String (SAS) match
        XCTAssertEqual(hostSAS.count, 6)
        XCTAssertEqual(clientSAS.count, 6)
        XCTAssertEqual(hostSAS, clientSAS, "Both devices must independently compute identical 6-digit SAS codes")

        // 8. iPhone user confirms matching SAS code
        let confirmation = try await clientSession.createConfirmation(isApproved: true)
        XCTAssertTrue(confirmation.isApproved)
        XCTAssertFalse(confirmation.clientSignatureHex.isEmpty)

        // 9. Mac processes confirmation, verifies client signature, and records trusted iPhone
        let (completion, hostRecord) = try await hostSession.processConfirmation(
            confirmation,
            trustStore: hostTrustStore
        )
        XCTAssertTrue(completion.isSuccessful)
        XCTAssertEqual(hostRecord.peer.publicKeyHex, clientIdentity.identity.publicKeyHex)
        XCTAssertFalse(hostRecord.isRevoked)

        // 10. iPhone processes completion, verifies host approval signature, and records trusted Mac
        let clientRecord = try await clientSession.completePairing(
            completion,
            trustStore: clientTrustStore
        )
        XCTAssertEqual(clientRecord.peer.publicKeyHex, hostIdentity.identity.publicKeyHex)
        XCTAssertFalse(clientRecord.isRevoked)

        // 11. Verify both trust stores now contain active trusted records
        let hostHasClient = await hostTrustStore.isDeviceTrusted(publicKeyHex: clientIdentity.identity.publicKeyHex)
        XCTAssertTrue(hostHasClient, "Host Mac must trust iPhone")

        let clientHasHost = await clientTrustStore.isDeviceTrusted(publicKeyHex: hostIdentity.identity.publicKeyHex)
        XCTAssertTrue(clientHasHost, "Client iPhone must trust Mac")
    }

    // MARK: - 2. Single-Use Invitation Consumption Enforcement

    func testSingleUseInvitationConsumption() async throws {
        let hostIdentity = try CryptoIdentity.createNew(
            label: "test.host.singleuse",
            displayName: "Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 15.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let clientIdentity = try CryptoIdentity.createNew(
            label: "test.client.singleuse",
            displayName: "iPhone",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "iOS 18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "test.host.truststore")

        let hostSession = HostPairingSession(hostIdentity: hostIdentity)
        let clientSession = try ClientPairingSession(invitation: hostSession.invitation, clientIdentity: clientIdentity)

        // Complete first pairing handshake
        let request = await clientSession.createRequest()
        let (response, _) = try await hostSession.processRequest(request)
        _ = try await clientSession.processResponse(response)
        let confirmation = try await clientSession.createConfirmation(isApproved: true)
        _ = try await hostSession.processConfirmation(confirmation, trustStore: hostTrustStore)

        // Attempting to reuse the consumed invitation must fail
        do {
            _ = try await hostSession.processRequest(request)
            XCTFail("Expected invitationReused error")
        } catch {
            XCTAssertEqual(error as? PairingError, .invitationReused)
        }

        do {
            _ = try await hostSession.processConfirmation(confirmation, trustStore: hostTrustStore)
            XCTFail("Expected invitationReused error")
        } catch {
            XCTAssertEqual(error as? PairingError, .invitationReused)
        }
    }

    // MARK: - 3. Expired Invitation Rejection

    func testExpiredInvitationRejection() throws {
        let hostIdentity = try CryptoIdentity.createNew(
            label: "test.host.expired",
            displayName: "Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 15.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let clientIdentity = try CryptoIdentity.createNew(
            label: "test.client.expired",
            displayName: "iPhone",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "iOS 18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )

        // Create invitation that has already expired (-1 second lifetime)
        let hostSession = HostPairingSession(hostIdentity: hostIdentity, lifetimeSeconds: -1.0)
        XCTAssertTrue(hostSession.invitation.isExpired())

        // Client must reject expired invitation upon initialization
        XCTAssertThrowsError(try ClientPairingSession(invitation: hostSession.invitation, clientIdentity: clientIdentity)) { error in
            XCTAssertEqual(error as? PairingError, .invitationExpired)
        }
    }

    // MARK: - 4. MITM Signature Tampering Rejection

    func testMITMSignatureTamperingRejection() async throws {
        let hostIdentity = try CryptoIdentity.createNew(
            label: "test.host.mitm",
            displayName: "Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 15.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let clientIdentity = try CryptoIdentity.createNew(
            label: "test.client.mitm",
            displayName: "iPhone",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "iOS 18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "test.host.truststore")

        let hostSession = HostPairingSession(hostIdentity: hostIdentity)
        let clientSession = try ClientPairingSession(invitation: hostSession.invitation, clientIdentity: clientIdentity)

        let request = await clientSession.createRequest()
        let (response, _) = try await hostSession.processRequest(request)

        // 1. Attacker tampers with host signature in response
        var tamperedHostSig = Data(hexString: response.hostSignatureHex)!
        tamperedHostSig[0] ^= 0xFF
        let tamperedResponse = PairingResponse(
            invitationId: response.invitationId,
            hostIdentity: response.hostIdentity,
            hostEphemeralPublicKeyHex: response.hostEphemeralPublicKeyHex,
            hostSignatureHex: tamperedHostSig.hexString,
            sasFingerprintCode: ""
        )

        do {
            _ = try await clientSession.processResponse(tamperedResponse)
            XCTFail("Expected transcriptVerificationFailed error")
        } catch {
            XCTAssertEqual(error as? PairingError, .transcriptVerificationFailed)
        }

        // 2. Client processes legitimate response, but attacker tampers with client confirmation signature
        _ = try await clientSession.processResponse(response)
        let confirmation = try await clientSession.createConfirmation(isApproved: true)

        var tamperedClientSig = Data(hexString: confirmation.clientSignatureHex)!
        tamperedClientSig[0] ^= 0xFF
        let tamperedConfirmation = PairingConfirmation(
            invitationId: confirmation.invitationId,
            isApproved: true,
            clientSignatureHex: tamperedClientSig.hexString,
            confirmedSASCode: confirmation.confirmedSASCode
        )

        do {
            _ = try await hostSession.processConfirmation(tamperedConfirmation, trustStore: hostTrustStore)
            XCTFail("Expected transcriptVerificationFailed error")
        } catch {
            XCTAssertEqual(error as? PairingError, .transcriptVerificationFailed)
        }
    }

    // MARK: - 5. Unilateral Rejection (User Disapproval)

    func testUserRejectionTerminatesHandshake() async throws {
        let hostIdentity = try CryptoIdentity.createNew(
            label: "test.host.unapproved",
            displayName: "Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 15.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let clientIdentity = try CryptoIdentity.createNew(
            label: "test.client.unapproved",
            displayName: "iPhone",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "iOS 18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "test.host.truststore")

        let hostSession = HostPairingSession(hostIdentity: hostIdentity)
        let clientSession = try ClientPairingSession(invitation: hostSession.invitation, clientIdentity: clientIdentity)

        let request = await clientSession.createRequest()
        let (response, _) = try await hostSession.processRequest(request)
        _ = try await clientSession.processResponse(response)

        // iPhone user clicks "Cancel" / "Reject"
        let rejection = try await clientSession.createConfirmation(isApproved: false)
        XCTAssertFalse(rejection.isApproved)

        do {
            _ = try await hostSession.processConfirmation(rejection, trustStore: hostTrustStore)
            XCTFail("Expected unapproved error")
        } catch {
            XCTAssertEqual(error as? PairingError, .unapproved)
        }

        // Verify no trusted device was registered
        let isTrusted = await hostTrustStore.isDeviceTrusted(publicKeyHex: clientIdentity.identity.publicKeyHex)
        XCTAssertFalse(isTrusted, "Rejected device must not be trusted")
    }

    // MARK: - 7. Pairing Stages Progression & Diagnostic Semantics

    func testPairingStagesEnumSemanticsAndProgression() {
        let stages: [PairingStage] = [
            .qrDetected,
            .invitationParsing,
            .invitationValidating,
            .resolvingHost(hostName: "MacBook Air M4"),
            .connectingSocket(endpoint: "192.168.1.50:5894"),
            .exchangingEphemeralKeys,
            .waitingForMacResponse,
            .derivingVerificationCode,
            .waitingForMutualConfirmation(sasCode: "849201"),
            .sendingConfirmation,
            .pairingCompleted(peer: DeviceIdentity(
                publicKeyHex: "04" + String(repeating: "aa", count: 64),
                displayName: "MacBook Air",
                deviceType: .mac,
                modelIdentifier: "Mac15,3",
                systemVersion: "macOS 15.0"
            )),
            .pairingFailed(reason: "Discovery timed out.")
        ]

        for stage in stages {
            XCTAssertFalse(stage.title.isEmpty, "Stage \(stage) must provide a title")
            XCTAssertFalse(stage.detail.isEmpty, "Stage \(stage) must provide a diagnostic detail")
            XCTAssertFalse(stage.sfSymbolName.isEmpty, "Stage \(stage) must provide an SF Symbol name")
        }

        XCTAssertEqual(PairingStage.qrDetected.sfSymbolName, "qrcode")
        XCTAssertEqual(PairingStage.invitationValidating.sfSymbolName, "checkmark.shield")
        XCTAssertEqual(PairingStage.waitingForMutualConfirmation(sasCode: "123456").title, "Confirm Security Code")
        let testPeer = DeviceIdentity(
            publicKeyHex: "04aa",
            displayName: "Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 15.0"
        )
        XCTAssertEqual(PairingStage.pairingCompleted(peer: testPeer).sfSymbolName, "checkmark.seal.fill")
        XCTAssertEqual(PairingStage.pairingFailed(reason: "Error").sfSymbolName, "xmark.octagon.fill")
    }
}
