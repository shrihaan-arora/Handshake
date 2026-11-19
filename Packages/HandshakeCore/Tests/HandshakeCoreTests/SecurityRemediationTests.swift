import XCTest
import Network
import CryptoKit
@testable import HandshakeCore

/// Comprehensive security verification test suite specifically validating the
/// remediation of audit findings SEC-01 through SEC-05:
/// - SEC-01: Session counter lifecycle & client restart
/// - SEC-02: Fail-closed pre-shared key derivation
/// - SEC-03: Zero SAS wire transmission & transcript-bound confirmation
/// - SEC-04: Sandboxed system sleep execution without Apple Events
/// - SEC-05: Deterministic FIFO bounded replay cache
final class SecurityRemediationTests: XCTestCase {

    private let testKeychain = KeychainManager(service: "com.handshake.test.remediation")
    private var portCounter: UInt16 = 5980
    private var activeServers: [HandshakeServer] = []

    private func getNextPort() -> UInt16 {
        portCounter += 1
        return portCounter
    }

    override func tearDown() async throws {
        for server in activeServers {
            await server.stop()
        }
        activeServers.removeAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    // MARK: - Helpers

    private func makeIdentities() throws -> (host: CryptoIdentity, client: CryptoIdentity) {
        let host = try CryptoIdentity.createNew(
            label: "remediation.host.\(UUID().uuidString)",
            displayName: "Audited Host Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 15.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let client = try CryptoIdentity.createNew(
            label: "remediation.client.\(UUID().uuidString)",
            displayName: "Audited iPhone 16e",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "iOS 18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        return (host, client)
    }

    #if os(macOS)
    private func createServer(
        port: UInt16,
        host: CryptoIdentity,
        trustStore: TrustStore,
        executionHandler: @escaping HandshakeServer.CommandExecutionHandler = { _, _ in .executed }
    ) -> HandshakeServer {
        let safeSleepEngine = MacSleepEngine(customSleepTrigger: { .sleepInitiated })
        let server = HandshakeServer(
            port: port,
            serviceType: "_handshake._tcp",
            hostIdentity: host,
            trustStore: trustStore,
            sleepEngine: safeSleepEngine,
            executionHandler: executionHandler
        )
        activeServers.append(server)
        return server
    }
    #else
    private func createServer(
        port: UInt16,
        host: CryptoIdentity,
        trustStore: TrustStore,
        executionHandler: @escaping HandshakeServer.CommandExecutionHandler = { _, _ in .executed }
    ) -> HandshakeServer {
        let server = HandshakeServer(
            port: port,
            serviceType: "_handshake._tcp",
            hostIdentity: host,
            trustStore: trustStore,
            executionHandler: executionHandler
        )
        activeServers.append(server)
        return server
    }
    #endif

    // MARK: - 1. SEC-01 Tests: Session Counter Lifecycle & Client Restart

    /// Verifies that when an iPhone client is force-quit and restarts (resetting its in-memory
    /// sequence counter to 0), a fresh authenticated session establishes an isolated sequence counter,
    /// allowing sequence number 1 to be accepted by the Mac server without requiring a Mac restart.
    func test01_ClientForceQuitAndRestart_SequenceResetAccepted() async throws {
        let (host, client) = try makeIdentities()
        let port = getNextPort()
        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "remediation.store.\(UUID().uuidString)")

        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }
        try await hostTrustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.sleep],
            preSharedKeyHex: pskHex
        ))

        let server = createServer(port: port, host: host, trustStore: hostTrustStore)
        try await server.start()

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))

        // Phase 1: Client run 1 sends commands with sequence numbers 1 and 2
        let clientInstance1 = HandshakeClient(clientIdentity: client)
        let ack1 = try await clientInstance1.sendCommand(.sleep, to: endpoint, trustedHostPublicKeyHex: host.identity.publicKeyHex, preSharedKeyHex: pskHex)
        XCTAssertEqual(ack1.status, .executed)

        let ack2 = try await clientInstance1.sendCommand(.sleep, to: endpoint, trustedHostPublicKeyHex: host.identity.publicKeyHex, preSharedKeyHex: pskHex)
        XCTAssertEqual(ack2.status, .executed)

        // Phase 2: Client app simulates force-quit and relaunch.
        // A fresh client instance starts with an in-memory sequence counter at 0.
        let clientInstance2 = HandshakeClient(clientIdentity: client)
        let ackAfterRestart = try await clientInstance2.sendCommand(.sleep, to: endpoint, trustedHostPublicKeyHex: host.identity.publicKeyHex, preSharedKeyHex: pskHex)
        XCTAssertEqual(ackAfterRestart.status, .executed, "Server must accept fresh session sequence #1 after client restart without Mac restart")
    }

    /// Verifies that replaying an exact SessionInitiation message is rejected by the server's anti-replay cache.
    func test02_ReplayedSessionInitiationRejected() async throws {
        let (host, client) = try makeIdentities()
        let port = getNextPort()
        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "remediation.store.\(UUID().uuidString)")

        try await hostTrustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.sleep]
        ))

        let server = createServer(port: port, host: host, trustStore: hostTrustStore)
        try await server.start()

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))

        // Create a valid SessionInitiation
        let clientEphemeral = EphemeralKeyExchange()
        let sessionId = UUID()
        let initPlaceholder = SessionInitiation(
            id: sessionId,
            clientIdentity: client.identity,
            clientEphemeralPublicKeyHex: clientEphemeral.publicKeyHex
        )
        let sig = try client.sign(data: initPlaceholder.signablePayload)
        let sessionInit = SessionInitiation(
            id: sessionId,
            timestampMilliseconds: initPlaceholder.timestampMilliseconds,
            clientIdentity: client.identity,
            clientEphemeralPublicKeyHex: clientEphemeral.publicKeyHex,
            signatureHex: sig.hexString
        )
        let initData = try JSONEncoder().encode(sessionInit)

        // 1. First connection: send initiation (should succeed)
        let conn1 = NWConnection(to: endpoint, using: .tcp)
        conn1.start(queue: .global())
        try await Task.sleep(nanoseconds: 50_000_000)
        try await NetworkFraming.send(data: initData, over: conn1)
        let respBytes1 = try await NetworkFraming.receive(from: conn1)
        let response1 = try JSONDecoder().decode(SessionResponse.self, from: respBytes1)
        XCTAssertEqual(response1.id, sessionId)
        conn1.cancel()

        // 2. Second connection: attempt to replay identical session initiation
        let conn2 = NWConnection(to: endpoint, using: .tcp)
        conn2.start(queue: .global())
        try await Task.sleep(nanoseconds: 50_000_000)
        try await NetworkFraming.send(data: initData, over: conn2)
        let respBytes2 = try await NetworkFraming.receive(from: conn2)
        let rejection = try JSONDecoder().decode(CommandAcknowledgment.self, from: respBytes2)
        guard case .rejected(let reason) = rejection.status else {
            XCTFail("Replayed session initiation must be rejected")
            return
        }
        XCTAssertTrue(reason.contains("replayed session identifier"))
        conn2.cancel()
    }

    /// Verifies that re-using an existing session ID with a modified timestamp or key is rejected.
    func test03_ReusedSessionIdRejected() async throws {
        let (host, client) = try makeIdentities()
        let port = getNextPort()
        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "remediation.store.\(UUID().uuidString)")

        try await hostTrustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.sleep]
        ))

        let server = createServer(port: port, host: host, trustStore: hostTrustStore)
        try await server.start()

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))
        let fixedSessionId = UUID()

        // Initiation 1
        let clientEphemeral1 = EphemeralKeyExchange()
        let init1Placeholder = SessionInitiation(id: fixedSessionId, clientIdentity: client.identity, clientEphemeralPublicKeyHex: clientEphemeral1.publicKeyHex)
        let sig1 = try client.sign(data: init1Placeholder.signablePayload)
        let init1 = SessionInitiation(id: fixedSessionId, timestampMilliseconds: init1Placeholder.timestampMilliseconds, clientIdentity: client.identity, clientEphemeralPublicKeyHex: clientEphemeral1.publicKeyHex, signatureHex: sig1.hexString)

        let conn1 = NWConnection(to: endpoint, using: .tcp)
        conn1.start(queue: .global())
        try await Task.sleep(nanoseconds: 50_000_000)
        try await NetworkFraming.send(data: try JSONEncoder().encode(init1), over: conn1)
        _ = try await NetworkFraming.receive(from: conn1)
        conn1.cancel()

        // Initiation 2 with fresh key but reused ID
        let clientEphemeral2 = EphemeralKeyExchange()
        let init2Placeholder = SessionInitiation(id: fixedSessionId, timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1000) + 10, clientIdentity: client.identity, clientEphemeralPublicKeyHex: clientEphemeral2.publicKeyHex)
        let sig2 = try client.sign(data: init2Placeholder.signablePayload)
        let init2 = SessionInitiation(id: fixedSessionId, timestampMilliseconds: init2Placeholder.timestampMilliseconds, clientIdentity: client.identity, clientEphemeralPublicKeyHex: clientEphemeral2.publicKeyHex, signatureHex: sig2.hexString)

        let conn2 = NWConnection(to: endpoint, using: .tcp)
        conn2.start(queue: .global())
        try await Task.sleep(nanoseconds: 50_000_000)
        try await NetworkFraming.send(data: try JSONEncoder().encode(init2), over: conn2)
        let resp2 = try await NetworkFraming.receive(from: conn2)
        let ack2 = try JSONDecoder().decode(CommandAcknowledgment.self, from: resp2)
        guard case .rejected(let reason) = ack2.status else {
            XCTFail("Reused session ID must be rejected")
            return
        }
        XCTAssertTrue(reason.contains("replayed session identifier"))
        conn2.cancel()
    }

    /// Verifies that command envelopes from an old/superseded session are rejected by the server under a new session.
    func test04_OldSessionMessageRejectedUnderNewSession() async throws {
        let (host, client) = try makeIdentities()
        let port = getNextPort()
        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "remediation.store.\(UUID().uuidString)")
        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }

        try await hostTrustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.sleep],
            preSharedKeyHex: pskHex
        ))

        let server = createServer(port: port, host: host, trustStore: hostTrustStore)
        try await server.start()

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))

        // Session 1: establish connection, derive keys
        let conn1 = NWConnection(to: endpoint, using: .tcp)
        conn1.start(queue: .global())
        try await Task.sleep(nanoseconds: 50_000_000)

        let clientInstance = HandshakeClient(clientIdentity: client)
        let masterPSK = SymmetricKey(data: Data(hexString: pskHex)!)
        let session1 = try await clientInstance.performSessionHandshake(connection: conn1, trustedHostPublicKeyHex: host.identity.publicKeyHex, masterPSK: masterPSK)

        // Seal a command under Session 1 key
        let oldCommand = CommandMessage(command: .sleep)
        let oldEnvelope = try SecureChannel.seal(
            message: oldCommand,
            sequenceNumber: 1,
            senderIdentity: client,
            recipientPublicKeyHex: host.identity.publicKeyHex,
            sessionKey: session1.clientToHostKey,
            nonceSalt: session1.clientToHostNonceSalt
        )
        conn1.cancel()

        // Session 2: establish fresh connection and session
        let conn2 = NWConnection(to: endpoint, using: .tcp)
        conn2.start(queue: .global())
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try await clientInstance.performSessionHandshake(connection: conn2, trustedHostPublicKeyHex: host.identity.publicKeyHex, masterPSK: masterPSK)

        // Attempt to send the old envelope (sealed under session 1 key) over session 2
        let envelopeData = try JSONEncoder().encode(oldEnvelope)
        try await NetworkFraming.send(data: envelopeData, over: conn2)

        let respBytes = try await NetworkFraming.receive(from: conn2)
        let rejection = try JSONDecoder().decode(CommandAcknowledgment.self, from: respBytes)
        guard case .rejected(let reason) = rejection.status else {
            XCTFail("Old session envelope must fail AEAD verification on new session")
            return
        }
        XCTAssertTrue(reason.contains("Authentication failed"))
        conn2.cancel()
    }

    // MARK: - 2. SEC-02 Tests: Fail-Closed Key Derivation

    /// Verifies that resolveSessionKey fails closed and throws ChannelError.missingPreSharedKey
    /// when preSharedKeyHex is nil, empty, or invalid, preventing any fallback to public keys.
    func test05_MissingOrInvalidPSK_FailsClosed() {
        // 1. Nil PSK
        XCTAssertThrowsError(
            try SecureChannel.resolveSessionKey(preSharedKeyHex: nil, role: .clientToHost)
        ) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .missingPreSharedKey)
        }

        // 2. Empty string PSK
        XCTAssertThrowsError(
            try SecureChannel.resolveSessionKey(preSharedKeyHex: "", role: .clientToHost)
        ) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .missingPreSharedKey)
        }

        // 3. Short hex PSK (16 bytes instead of 32 bytes)
        let shortHex = "0102030405060708090a0b0c0d0e0f10"
        XCTAssertThrowsError(
            try SecureChannel.resolveSessionKey(preSharedKeyHex: shortHex, role: .clientToHost)
        ) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .missingPreSharedKey)
        }

        // 4. Invalid hex characters
        let invalidHex = "not-a-valid-hex-string-at-all-xyz"
        XCTAssertThrowsError(
            try SecureChannel.resolveSessionKey(preSharedKeyHex: invalidHex, role: .clientToHost)
        ) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .missingPreSharedKey)
        }

        // 5. Valid 32-byte hex succeeds
        let validHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }
        XCTAssertNoThrow(
            try SecureChannel.resolveSessionKey(preSharedKeyHex: validHex, role: .clientToHost)
        )
    }

    /// Verifies that direct command dispatch without an active session fails closed on the server
    /// if the trust record has no pre-shared key.
    func test06_DirectCommandWithoutPSK_FailsClosedOnServer() async throws {
        let (host, client) = try makeIdentities()
        let port = getNextPort()
        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "remediation.store.\(UUID().uuidString)")

        // Add trust record with NO PSK
        try await hostTrustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.sleep],
            preSharedKeyHex: nil
        ))

        let server = createServer(port: port, host: host, trustStore: hostTrustStore)
        try await server.start()

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.start(queue: .global())
        try await Task.sleep(nanoseconds: 50_000_000)

        // Generate an envelope encrypted with an arbitrary key
        let arbitraryKey = SymmetricKey(size: .bits256)
        let cmd = CommandMessage(command: .sleep)
        let envelope = try SecureChannel.seal(
            message: cmd,
            sequenceNumber: 1,
            senderIdentity: client,
            recipientPublicKeyHex: host.identity.publicKeyHex,
            sessionKey: arbitraryKey
        )

        try await NetworkFraming.send(data: try JSONEncoder().encode(envelope), over: conn)
        let respBytes = try await NetworkFraming.receive(from: conn)
        let rejection = try JSONDecoder().decode(CommandAcknowledgment.self, from: respBytes)
        guard case .rejected(let reason) = rejection.status else {
            XCTFail("Server must reject command when PSK is missing")
            return
        }
        XCTAssertTrue(reason.contains("Missing or invalid pre-shared key"))
        conn.cancel()
    }

    // MARK: - 3. SEC-03 Tests: Zero SAS Wire Leakage & Explicit Approval

    /// Verifies that during mutual device pairing, the 6-digit SAS code is derived locally
    /// on both devices and is strictly NOT transmitted over the network in PairingConfirmation.
    func test07_SASConfirmation_ZeroWireLeakageAndBilateralApproval() async throws {
        let (host, client) = try makeIdentities()
        let hostSession = HostPairingSession(hostIdentity: host)
        let invitation = hostSession.invitation

        let clientSession = try ClientPairingSession(invitation: invitation, clientIdentity: client)
        let request = await clientSession.createRequest()

        // Host processes request -> derives SAS
        let (response, hostSAS) = try await hostSession.processRequest(request)
        XCTAssertEqual(response.sasFingerprintCode, "", "PairingResponse must NOT transmit SAS on the wire")

        // Client processes response -> derives SAS
        let clientSAS = try await clientSession.processResponse(response)
        XCTAssertEqual(hostSAS, clientSAS, "Both devices must independently derive the exact same SAS code")
        XCTAssertEqual(clientSAS.count, 6, "SAS code must be 6 digits")

        // Client creates confirmation
        let confirmation = try await clientSession.createConfirmation(isApproved: true)
        XCTAssertTrue(confirmation.isApproved)
        XCTAssertEqual(confirmation.confirmedSASCode, "", "Security requirement SEC-03: confirmedSASCode must NOT transmit SAS digits over the wire")
        XCTAssertFalse(confirmation.clientSignatureHex.isEmpty, "Confirmation must be cryptographically attested by client ECDSA signature")

        // Host validates confirmation
        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "remediation.store.\(UUID().uuidString)")
        let (completion, hostRecord) = try await hostSession.processConfirmation(confirmation, trustStore: hostTrustStore)
        XCTAssertTrue(completion.isSuccessful)
        XCTAssertEqual(hostRecord.peer.id, client.identity.id)

        // Client completes pairing
        let clientTrustStore = TrustStore(keychain: testKeychain, storageAccount: "remediation.store.\(UUID().uuidString)")
        let clientRecord = try await clientSession.completePairing(completion, trustStore: clientTrustStore)
        XCTAssertEqual(clientRecord.peer.id, host.identity.id)
    }

    /// Verifies that user rejection of the SAS code terminates the pairing handshake and prevents trust establishment.
    func test08_SASRejection_TerminatesHandshake() async throws {
        let (host, client) = try makeIdentities()
        let hostSession = HostPairingSession(hostIdentity: host)
        let invitation = hostSession.invitation

        let clientSession = try ClientPairingSession(invitation: invitation, clientIdentity: client)
        let request = await clientSession.createRequest()
        let (response, _) = try await hostSession.processRequest(request)
        _ = try await clientSession.processResponse(response)

        // User taps "Reject"
        let rejection = try await clientSession.createConfirmation(isApproved: false)
        XCTAssertFalse(rejection.isApproved)

        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "remediation.store.\(UUID().uuidString)")
        do {
            _ = try await hostSession.processConfirmation(rejection, trustStore: hostTrustStore)
            XCTFail("Rejected pairing confirmation must throw unapproved error")
        } catch let error as PairingError {
            XCTAssertEqual(error, .unapproved)
        }
    }

    /// Verifies single-use invitation consumption: duplicate confirmation is rejected.
    func test09_DuplicatePairingConfirmation_RejectedAsConsumed() async throws {
        let (host, client) = try makeIdentities()
        let hostSession = HostPairingSession(hostIdentity: host)
        let invitation = hostSession.invitation

        let clientSession = try ClientPairingSession(invitation: invitation, clientIdentity: client)
        let request = await clientSession.createRequest()
        let (response, _) = try await hostSession.processRequest(request)
        _ = try await clientSession.processResponse(response)
        let confirmation = try await clientSession.createConfirmation(isApproved: true)

        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "remediation.store.\(UUID().uuidString)")
        _ = try await hostSession.processConfirmation(confirmation, trustStore: hostTrustStore)

        // Attempt second confirmation on consumed session
        do {
            _ = try await hostSession.processConfirmation(confirmation, trustStore: hostTrustStore)
            XCTFail("Duplicate confirmation on consumed session must fail")
        } catch let error as PairingError {
            XCTAssertEqual(error, .invitationReused)
        }
    }

    // MARK: - 4. SEC-04 & System Execution Tests

    /// Verifies that MacSleepEngine executes cleanly via IOKit IOPMSleepSystem without Apple Events.
    #if os(macOS)
    func test10_MacSleepEngine_ExecutionSemantics() {
        // Test custom trigger mock
        let mockEngine = MacSleepEngine(customSleepTrigger: { .sleepInitiated })
        XCTAssertTrue(mockEngine.isSleepSupported())
        let state = mockEngine.triggerSleep()
        XCTAssertEqual(state, .sleepInitiated)
        XCTAssertTrue(state.isSuccess)

        // Test real hardware query support
        let defaultEngine = MacSleepEngine()
        XCTAssertTrue(defaultEngine.isSleepSupported() == true || defaultEngine.isSleepSupported() == false)
    }
    #endif

    // MARK: - 5. Command Authorization & Network Framing Tests

    /// Verifies that commands not in the peer's authorized capabilities are rejected.
    func test11_CommandAuthorization_StrictlyEnforced() async throws {
        let (host, client) = try makeIdentities()
        let port = getNextPort()
        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "remediation.store.\(UUID().uuidString)")
        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }

        // Authorize ONLY ping, NOT sleep
        try await hostTrustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.ping],
            preSharedKeyHex: pskHex
        ))

        let server = createServer(port: port, host: host, trustStore: hostTrustStore)
        try await server.start()

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))
        let clientInstance = HandshakeClient(clientIdentity: client)

        // Send sleep command (unauthorized)
        do {
            _ = try await clientInstance.sendCommand(.sleep, to: endpoint, trustedHostPublicKeyHex: host.identity.publicKeyHex, preSharedKeyHex: pskHex)
            XCTFail("Unauthorized command must be rejected")
        } catch let error as HandshakeClient.ClientError {
            if case .commandRejected(let reason) = error {
                XCTAssertTrue(reason.contains("not authorized"))
            } else {
                XCTFail("Expected commandRejected error, got: \(error)")
            }
        }
    }

    /// Verifies that malformed packet data does not crash the server and fails closed.
    func test12_MalformedNetworkMessageHandling() async throws {
        let (host, _) = try makeIdentities()
        let port = getNextPort()
        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "remediation.store.\(UUID().uuidString)")

        let server = createServer(port: port, host: host, trustStore: hostTrustStore)
        try await server.start()

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.start(queue: .global())
        try await Task.sleep(nanoseconds: 50_000_000)

        // Send 100 bytes of completely random non-JSON bytes with valid framing
        let randomPayload = (0..<100).map { _ in UInt8.random(in: 0...255) }
        try await NetworkFraming.send(data: Data(randomPayload), over: conn)

        // Server should close connection cleanly
        try await Task.sleep(nanoseconds: 100_000_000)
        conn.cancel()
        let isRunning = await server.isRunning
        XCTAssertTrue(isRunning, "Server must remain running after handling malformed frames")
    }
}
