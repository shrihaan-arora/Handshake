import Foundation
@preconcurrency import CoreBluetooth
import CryptoKit

/// Shared BLE constants for the Handshake peer protocol.
public enum BLEConstants {
    public static let serviceUUIDString = "A67D5894-0409-411B-8233-000000000001"
    public static let commandCharacteristicUUIDString = "A67D5894-0409-411B-8233-000000000002"
    public static let ackCharacteristicUUIDString = "A67D5894-0409-411B-8233-000000000003"

    public static var serviceUUID: CBUUID { CBUUID(string: serviceUUIDString) }
    public static var commandCharacteristicUUID: CBUUID { CBUUID(string: commandCharacteristicUUIDString) }
    public static var ackCharacteristicUUID: CBUUID { CBUUID(string: ackCharacteristicUUIDString) }
    public static let maxChunkSize: Int = 180
}

/// Errors occurring during CoreBluetooth peer operations.
public enum BLETransportError: Error, LocalizedError, Equatable {
    case bluetoothPoweredOff
    case bluetoothUnauthorized
    case bluetoothUnsupported
    case scanningTimedOut
    case connectionFailed(String)
    case serviceNotFound
    case characteristicNotFound
    case transferFailed(String)
    case invalidAcknowledgment
    case disconnected
    case timeout

    public var errorDescription: String? {
        switch self {
        case .bluetoothPoweredOff:
            return "Bluetooth is turned off. Please enable Bluetooth in Settings."
        case .bluetoothUnauthorized:
            return "Bluetooth permission has not been granted."
        case .bluetoothUnsupported:
            return "Bluetooth Low Energy is not supported on this device."
        case .scanningTimedOut:
            return "Scanning timed out. Ensure Handshake companion is active on your Mac."
        case .connectionFailed(let msg):
            return "Bluetooth connection failed: \(msg)"
        case .serviceNotFound:
            return "Handshake BLE service not found on peripheral."
        case .characteristicNotFound:
            return "Handshake BLE characteristics not found on peripheral."
        case .transferFailed(let msg):
            return "Bluetooth data transfer failed: \(msg)"
        case .invalidAcknowledgment:
            return "Mac acknowledgment failed digital signature verification."
        case .disconnected:
            return "Bluetooth peripheral disconnected unexpectedly."
        case .timeout:
            return "Bluetooth operation timed out."
        }
    }
}

// MARK: - BLE Peripheral Host (Mac Companion)

#if os(macOS)
/// Mac companion BLE peripheral host that advertises and processes incoming commands over BLE.
/// Operates in parallel with the local TCP server to guarantee connectivity when devices are on different Wi-Fi networks.
public final class BLEPeripheralHost: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {

    private struct PendingSleep: Sendable {
        let commandId: UUID
        let clientPublicKeyHex: String
    }

    private let hostIdentity: CryptoIdentity
    private let trustStore: TrustStore
    private let sleepEngine: MacSleepEngine
    private let commandLogRepository: CommandLogRepository?
    private let pairingEventRepository: PairingEventRepository?
    private let deviceSessionRepository: DeviceSessionRepository?
    private let executionHandler: HandshakeServer.CommandExecutionHandler

    private var peripheralManager: CBPeripheralManager?
    private var commandChar: CBMutableCharacteristic?
    private var ackChar: CBMutableCharacteristic?
    private var isAdvertising: Bool = false

    private let lock = NSLock()
    private let reassembler = BLEPacketFraming.Reassembler()
    private var activeSession: EstablishedSession? = nil
    private var pendingSleep: PendingSleep? = nil
    private var connectedCentral: CBCentral? = nil
    private var readyToUpdateContinuation: CheckedContinuation<Void, Never>? = nil

    private var activePairingSession: HostPairingSession? = nil
    private var pairingApprovalHandler: HandshakeServer.PairingApprovalHandler? = nil
    private var macApprovalContinuation: CheckedContinuation<Bool, Never>? = nil
    private var isMacApproved: Bool? = nil

    public init(
        hostIdentity: CryptoIdentity,
        trustStore: TrustStore,
        sleepEngine: MacSleepEngine = MacSleepEngine(),
        commandLogRepository: CommandLogRepository? = nil,
        pairingEventRepository: PairingEventRepository? = nil,
        deviceSessionRepository: DeviceSessionRepository? = nil,
        executionHandler: @escaping HandshakeServer.CommandExecutionHandler = { _, _ in .executed }
    ) {
        self.hostIdentity = hostIdentity
        self.trustStore = trustStore
        self.sleepEngine = sleepEngine
        self.commandLogRepository = commandLogRepository
        self.pairingEventRepository = pairingEventRepository
        self.deviceSessionRepository = deviceSessionRepository
        self.executionHandler = executionHandler
        super.init()
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard peripheralManager == nil else { return }

        let queue = DispatchQueue(label: "com.handshake.ble.peripheral", qos: .userInitiated)
        peripheralManager = CBPeripheralManager(delegate: self, queue: queue)
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let manager = peripheralManager {
            if manager.isAdvertising {
                manager.stopAdvertising()
            }
            manager.removeAllServices()
            peripheralManager = nil
        }
        isAdvertising = false
        reassembler.reset()
        activeSession = nil
        pendingSleep = nil
    }

    public var advertising: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isAdvertising
    }

    private func setAdvertising(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        isAdvertising = value
    }

    private func setSession(_ session: EstablishedSession?) {
        lock.lock()
        defer { lock.unlock() }
        activeSession = session
    }

    private func getSession() -> EstablishedSession? {
        lock.lock()
        defer { lock.unlock() }
        return activeSession
    }

    private func setPendingSleep(commandId: UUID, clientPublicKeyHex: String) {
        lock.lock()
        defer { lock.unlock() }
        pendingSleep = PendingSleep(commandId: commandId, clientPublicKeyHex: clientPublicKeyHex)
    }

    /// Atomically consumes the one pending sleep request. This is the single
    /// authority that may invoke IOPMSleepSystem for a BLE command.
    private func takePendingSleep(commandId: UUID? = nil, clientPublicKeyHex: String? = nil) -> PendingSleep? {
        lock.lock()
        defer { lock.unlock() }
        guard let pendingSleep else { return nil }
        if let commandId, pendingSleep.commandId != commandId { return nil }
        if let clientPublicKeyHex, pendingSleep.clientPublicKeyHex != clientPublicKeyHex { return nil }
        self.pendingSleep = nil
        return pendingSleep
    }

    private func setCentral(_ central: CBCentral?) {
        lock.lock()
        defer { lock.unlock() }
        connectedCentral = central
    }

    private func registerReadyContinuation(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        readyToUpdateContinuation = cont
    }

    private func takeReadyContinuation() -> CheckedContinuation<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let cont = readyToUpdateContinuation
        readyToUpdateContinuation = nil
        return cont
    }

    public func setActivePairingSession(_ session: HostPairingSession?, approvalHandler: HandshakeServer.PairingApprovalHandler? = nil) {
        lock.lock()
        defer { lock.unlock() }
        self.activePairingSession = session
        self.pairingApprovalHandler = approvalHandler
        self.isMacApproved = nil
        if let cont = macApprovalContinuation {
            macApprovalContinuation = nil
            cont.resume(returning: false)
        }
        if let s = session {
            print("[BLEPeripheralHost] Active pairing session registered over BLE: id=\(s.invitation.id)")
        } else {
            print("[BLEPeripheralHost] Active pairing session cleared over BLE.")
        }
    }

    private func getPairingSession() -> HostPairingSession? {
        lock.lock()
        defer { lock.unlock() }
        return activePairingSession
    }

    private func getPairingApprovalHandler() -> HandshakeServer.PairingApprovalHandler? {
        lock.lock()
        defer { lock.unlock() }
        return pairingApprovalHandler
    }

    private func registerMacApprovalContinuation(_ cont: CheckedContinuation<Bool, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if let decision = isMacApproved {
            cont.resume(returning: decision)
        } else {
            macApprovalContinuation = cont
        }
    }

    private func notifyMacApprovalDecision(_ approved: Bool) {
        lock.lock()
        defer { lock.unlock() }
        isMacApproved = approved
        if let cont = macApprovalContinuation {
            macApprovalContinuation = nil
            cont.resume(returning: approved)
        }
    }

    // MARK: - CBPeripheralManagerDelegate

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            setupServices(peripheral)
        } else {
            setAdvertising(false)
        }
    }

    private func setupServices(_ peripheral: CBPeripheralManager) {
        let cmdChar = CBMutableCharacteristic(
            type: BLEConstants.commandCharacteristicUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        let respChar = CBMutableCharacteristic(
            type: BLEConstants.ackCharacteristicUUID,
            properties: [.notify, .indicate, .read],
            value: nil,
            permissions: [.readable]
        )

        let service = CBMutableService(type: BLEConstants.serviceUUID, primary: true)
        service.characteristics = [cmdChar, respChar]

        self.commandChar = cmdChar
        self.ackChar = respChar

        peripheral.removeAllServices()
        peripheral.add(service)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            print("[BLEPeripheralHost] Error adding GATT service: \(error.localizedDescription)")
            return
        }
        let advertisementData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [BLEConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: hostIdentity.identity.displayName
        ]
        peripheral.startAdvertising(advertisementData)
        setAdvertising(true)
        print("[BLEPeripheralHost] Added service \(BLEConstants.serviceUUIDString) and started advertising as '\(hostIdentity.identity.displayName)'")
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            print("[BLEPeripheralHost] Advertising failed to start: \(error.localizedDescription)")
        } else {
            print("[BLEPeripheralHost] Advertising active on 2.4 GHz CoreBluetooth GATT")
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        print("[BLEPeripheralHost] Central connected and subscribed: \(central.identifier)")
        setCentral(central)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        print("[BLEPeripheralHost] Central unsubscribed: \(central.identifier)")
        setCentral(nil)
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        takeReadyContinuation()?.resume()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == BLEConstants.commandCharacteristicUUID, let data = request.value {
                print("[BLEPeripheralHost] Received GATT write slice: \(data.count) bytes from central \(request.central.identifier)")
                do {
                    if let completeFrame = try reassembler.processChunk(data) {
                        let central = request.central
                        print("[BLEPeripheralHost] Inbound BLE frame reassembled successfully: \(completeFrame.count) bytes")
                        Task {
                            await handleCompleteInboundFrame(completeFrame, from: central)
                        }
                    }
                } catch {
                    print("[BLEPeripheralHost] Framing error during chunk processing: \(error)")
                    reassembler.reset()
                }
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }

    // MARK: - Inbound Frame Dispatcher

    private func handleCompleteInboundFrame(_ rawData: Data, from central: CBCentral) async {
        // 1. SessionInitiation Handshake
        if let sessionInit = try? JSONDecoder().decode(SessionInitiation.self, from: rawData) {
            await handleSessionInitiation(sessionInit, central: central)
            return
        }

        // 2. Encrypted CommandEnvelope
        if let envelope = try? JSONDecoder().decode(CommandEnvelope.self, from: rawData) {
            await handleCommandEnvelope(envelope, central: central)
            return
        }

        // 3. CommandReceipt (Two-stage sleep confirmation)
        if let receipt = try? JSONDecoder().decode(CommandReceipt.self, from: rawData) {
            await handleCommandReceipt(receipt)
            return
        }

        // 4. PairingRequest. Its invitation ID must match the QR invitation
        // currently displayed on the Mac; BLE never supplies an invitation.
        if let pairingReq = try? JSONDecoder().decode(PairingRequest.self, from: rawData) {
            await handlePairingRequest(pairingReq, central: central)
            return
        }

        // 5. PairingConfirmation
        if let pairingConfirm = try? JSONDecoder().decode(PairingConfirmation.self, from: rawData) {
            await handlePairingConfirmation(pairingConfirm, central: central)
            return
        }
    }

    private func handlePairingRequest(_ pairingReq: PairingRequest, central: CBCentral) async {
        guard let hostSession = getPairingSession() else {
            print("[BLEPeripheralHost] PairingRequest received but no active pairing session on Mac.")
            let rejection = CommandAcknowledgment(
                commandId: pairingReq.invitationId,
                status: .rejected("No active pairing session on Mac. Open pairing screen on Mac."),
                hostIdentity: hostIdentity.identity
            )
            if let rejData = try? JSONEncoder().encode(rejection) {
                try? await sendFramedResponse(rejData, to: central)
            }
            return
        }

        do {
            let (response, derivedSAS) = try await hostSession.processRequest(pairingReq)
            _ = try? self.pairingEventRepository?.insert(PairingEventRecord(
                peerDeviceId: pairingReq.clientIdentity.id.uuidString,
                peerDeviceName: pairingReq.clientIdentity.displayName,
                eventType: "ble_pairing_requested",
                result: "success"
            ))

            // 1. Send PairingResponse to client over BLE
            let respData = try JSONEncoder().encode(response)
            try await sendFramedResponse(respData, to: central)
            print("[BLEPeripheralHost] Dispatched PairingResponse to central \(central.identifier) over BLE")

            // 2. Concurrently invoke Mac bilateral approval handler
            if let handler = getPairingApprovalHandler() {
                Task {
                    let approved = await handler(pairingReq.clientIdentity, derivedSAS)
                    self.notifyMacApprovalDecision(approved)
                }
            } else {
                self.notifyMacApprovalDecision(true)
            }
        } catch {
            print("[BLEPeripheralHost] PairingRequest processing error: \(error)")
            let rejection = CommandAcknowledgment(
                commandId: pairingReq.invitationId,
                status: .rejected("Pairing request failed: \(error.localizedDescription)"),
                hostIdentity: hostIdentity.identity
            )
            if let rejData = try? JSONEncoder().encode(rejection) {
                try? await sendFramedResponse(rejData, to: central)
            }
        }
    }

    private func handlePairingConfirmation(_ pairingConfirm: PairingConfirmation, central: CBCentral) async {
        guard let hostSession = getPairingSession() else {
            print("[BLEPeripheralHost] PairingConfirmation received without active session.")
            return
        }

        guard pairingConfirm.isApproved else {
            print("[BLEPeripheralHost] Client rejected pairing confirmation.")
            let failedComp = PairingCompletion(
                invitationId: pairingConfirm.invitationId,
                isSuccessful: false,
                hostApprovalSignatureHex: ""
            )
            if let compData = try? JSONEncoder().encode(failedComp) {
                try? await sendFramedResponse(compData, to: central)
            }
            setActivePairingSession(nil)
            return
        }

        // Wait for Mac user approval decision with timeout (60 seconds)
        let approved = await withCheckedContinuation { continuation in
            registerMacApprovalContinuation(continuation)
        }

        guard approved else {
            print("[BLEPeripheralHost] Mac user rejected pairing confirmation.")
            let failedComp = PairingCompletion(
                invitationId: pairingConfirm.invitationId,
                isSuccessful: false,
                hostApprovalSignatureHex: ""
            )
            if let compData = try? JSONEncoder().encode(failedComp) {
                try? await sendFramedResponse(compData, to: central)
            }
            setActivePairingSession(nil)
            return
        }

        do {
            let (completion, trustRecord) = try await hostSession.processConfirmation(pairingConfirm, trustStore: self.trustStore)
            let compData = try JSONEncoder().encode(completion)
            try await sendFramedResponse(compData, to: central)
            print("[BLEPeripheralHost] BLE Pairing completed successfully! TrustRecord pinned for \(trustRecord.peer.displayName)")
            _ = try? self.pairingEventRepository?.insert(PairingEventRecord(
                peerDeviceId: trustRecord.peer.id.uuidString,
                peerDeviceName: trustRecord.peer.displayName,
                eventType: "ble_pairing_completed",
                result: "success"
            ))
            setActivePairingSession(nil)
        } catch {
            print("[BLEPeripheralHost] Error completing pairing confirmation: \(error)")
            let failedComp = PairingCompletion(
                invitationId: pairingConfirm.invitationId,
                isSuccessful: false,
                hostApprovalSignatureHex: ""
            )
            if let compData = try? JSONEncoder().encode(failedComp) {
                try? await sendFramedResponse(compData, to: central)
            }
            setActivePairingSession(nil)
        }
    }

    private func handleSessionInitiation(_ sessionInit: SessionInitiation, central: CBCentral) async {
        guard HandshakeTime.isTimestampValid(sessionInit.timestampMilliseconds) else { return }

        guard let trustRecord = await trustStore.getRecord(publicKeyHex: sessionInit.clientIdentity.publicKeyHex),
              !trustRecord.isRevoked else { return }

        guard let clientSigData = Data(hexString: sessionInit.signatureHex),
              CryptoIdentity.verify(
                signatureRaw: clientSigData,
                for: sessionInit.signablePayload,
                publicKeyHex: trustRecord.peer.publicKeyHex
              ) else { return }

        do {
            let hostEphemeralKey = P256.KeyAgreement.PrivateKey()
            let hostEphemeralHex = hostEphemeralKey.publicKey.rawRepresentation.hexString

            guard let clientEphemeralBytes = Data(hexString: sessionInit.clientEphemeralPublicKeyHex),
                  let clientEphemeralKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: clientEphemeralBytes) else {
                return
            }

            let sharedSecret = try hostEphemeralKey.sharedSecretFromKeyAgreement(with: clientEphemeralKey)
            guard let masterPSK = await trustStore.retrievePreSharedKey(forPeerId: trustRecord.id) else {
                return // SEC-02 fail closed; persisted records intentionally omit PSKs.
            }

            let placeholder = SessionResponse(
                id: sessionInit.id,
                hostIdentity: hostIdentity.identity,
                hostEphemeralPublicKeyHex: hostEphemeralHex
            )
            var transcript = sessionInit.signablePayload
            transcript.append(placeholder.signablePayload)

            let keys = SessionKeyDerivation.deriveKeys(
                sharedSecret: sharedSecret,
                sessionId: sessionInit.id,
                transcript: transcript,
                masterPSK: masterPSK
            )

            let establishedSession = EstablishedSession(
                sessionId: sessionInit.id,
                peer: sessionInit.clientIdentity,
                clientToHostKey: keys.clientToHostKey,
                hostToClientKey: keys.hostToClientKey,
                clientToHostNonceSalt: keys.clientNonceSalt,
                hostToClientNonceSalt: keys.hostNonceSalt
            )

            setSession(establishedSession)

            let sig = try hostIdentity.sign(data: placeholder.signablePayload)
            let response = SessionResponse(
                id: sessionInit.id,
                timestampMilliseconds: placeholder.timestampMilliseconds,
                hostIdentity: hostIdentity.identity,
                hostEphemeralPublicKeyHex: hostEphemeralHex,
                signatureHex: sig.hexString
            )

            let respData = try JSONEncoder().encode(response)
            try await sendFramedResponse(respData, to: central)

            _ = try? self.deviceSessionRepository?.insert(DeviceSessionRecord(
                peerDeviceId: sessionInit.clientIdentity.id.uuidString,
                sessionStartedAt: DatabaseManager.iso8601String(),
                status: "active_ble"
            ))
        } catch {
            // Fail closed on handshake errors
        }
    }

    private func handleCommandEnvelope(_ envelope: CommandEnvelope, central: CBCentral) async {
        guard let session = getSession(), !session.isExpired() else { return }

        do {
            let message = try await SecureChannel.open(
                envelope: envelope,
                sessionKey: session.clientToHostKey,
                trustedSenderPublicKeyHex: session.peer.publicKeyHex,
                sequenceCounter: session.incomingSequenceCounter,
                expectedNonceSalt: session.clientToHostNonceSalt
            )

            guard let trustRecord = await trustStore.getRecord(publicKeyHex: session.peer.publicKeyHex),
                  trustRecord.authorizedCapabilities.contains(message.command) else {
                return
            }

            try? await trustStore.updateLastSeen(id: trustRecord.id)
            let status = await executionHandler(message, trustRecord.peer)

            let placeholder = CommandAcknowledgment(commandId: message.id, status: status, hostIdentity: hostIdentity.identity)
            let sig = try hostIdentity.sign(data: placeholder.signablePayload)
            let ack = CommandAcknowledgment(
                commandId: message.id,
                status: status,
                timestampMilliseconds: placeholder.timestampMilliseconds,
                hostIdentity: hostIdentity.identity,
                signatureHex: sig.hexString
            )

            let ackData = try JSONEncoder().encode(ack)
            try await sendFramedResponse(ackData, to: central)

            _ = try? self.commandLogRepository?.insert(CommandLogRecord(
                requestId: message.id.uuidString,
                peerDeviceId: session.peer.id.uuidString,
                peerDeviceName: session.peer.displayName,
                commandType: message.command.rawValue,
                receivedAt: DatabaseManager.iso8601String(),
                status: message.command == .sleep ? "accepted" : "executed",
                resultCode: message.command == .sleep ? "ACCEPTED" : "SUCCESS_BLE"
            ))

            // Sleep is intentionally deferred until a signed receipt arrives, or
            // the bounded fallback expires. `takePendingSleep` makes both paths
            // mutually exclusive, preventing duplicate IOKit calls.
            if message.command == .sleep && status == .accepted {
                setPendingSleep(commandId: message.id, clientPublicKeyHex: session.peer.publicKeyHex)
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let pending = self.takePendingSleep(commandId: message.id) else { return }
                    self.issueSleep(commandId: pending.commandId)
                }
            }
        } catch {
            // Drop invalid/unauthenticated commands
        }
    }

    private func handleCommandReceipt(_ receipt: CommandReceipt) async {
        guard let session = getSession(),
              receipt.clientIdentity.publicKeyHex == session.peer.publicKeyHex else { return }
        guard let sigData = Data(hexString: receipt.signatureHex),
              CryptoIdentity.verify(
                signatureRaw: sigData,
                for: receipt.signablePayload,
                publicKeyHex: session.peer.publicKeyHex
              ) else { return }

        guard let pending = takePendingSleep(
            commandId: receipt.commandId,
            clientPublicKeyHex: session.peer.publicKeyHex
        ) else { return }

        // Receipt was signed by the paired client for this exact command.
        try? await Task.sleep(nanoseconds: 100_000_000)
        issueSleep(commandId: pending.commandId)
    }

    private func issueSleep(commandId: UUID) {
        let result = sleepEngine.triggerSleep()
        let completion = DatabaseManager.iso8601String()
        switch result {
        case .sleepInitiated:
            try? commandLogRepository?.updateCompletion(
                requestId: commandId.uuidString,
                status: "sleep_request_issued",
                completedAt: completion,
                resultCode: "SLEEP_REQUEST_ISSUED",
                errorMessage: nil
            )
        case .failed(let reason):
            try? commandLogRepository?.updateCompletion(
                requestId: commandId.uuidString,
                status: "failed",
                completedAt: completion,
                resultCode: "FAILED",
                errorMessage: reason
            )
        case .sleepNotSupported:
            try? commandLogRepository?.updateCompletion(
                requestId: commandId.uuidString,
                status: "failed",
                completedAt: completion,
                resultCode: "UNSUPPORTED",
                errorMessage: "System sleep is not supported on this Mac"
            )
        default:
            break
        }
    }

    // MARK: - Outbound GATT Notification Sending

    private func sendFramedResponse(_ data: Data, to central: CBCentral) async throws {
        guard let ackChar = self.ackChar, let manager = self.peripheralManager else {
            throw BLETransportError.characteristicNotFound
        }

        let maxChunk = max(20, central.maximumUpdateValueLength)
        let chunks = try BLEPacketFraming.chunk(frame: data, maxChunkSize: maxChunk)

        for chunk in chunks {
            var sent = manager.updateValue(chunk, for: ackChar, onSubscribedCentrals: [central])
            while !sent {
                await withCheckedContinuation { cont in
                    self.registerReadyContinuation(cont)
                }
                sent = manager.updateValue(chunk, for: ackChar, onSubscribedCentrals: [central])
            }
        }
    }
}
#endif

// MARK: - BLE Central Client (iPhone)

/// Represents a Mac companion discovered over Bluetooth Low Energy.
public struct DiscoveredBLEHost: Identifiable, Sendable, Equatable {
    public var id: UUID { peripheral.identifier }
    public let peripheral: CBPeripheral
    public let name: String
    public let rssi: Int

    public init(peripheral: CBPeripheral, name: String, rssi: Int) {
        self.peripheral = peripheral
        self.name = name
        self.rssi = rssi
    }

    public static func == (lhs: DiscoveredBLEHost, rhs: DiscoveredBLEHost) -> Bool {
        lhs.peripheral.identifier == rhs.peripheral.identifier
    }
}

/// iPhone BLE central client that scans for Mac companion, establishes GATT connection,
/// exchanges mutual ephemeral cryptographic sessions, and issues authenticated commands.
public final class BLECentralClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {

    private let clientIdentity: CryptoIdentity
    private let sequenceCounter: SequenceCounter
    private let queue: DispatchQueue

    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var commandChar: CBCharacteristic?
    private var ackChar: CBCharacteristic?

    private var scanContinuation: CheckedContinuation<CBPeripheral, Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var charDiscoveryContinuation: CheckedContinuation<Void, Error>?
    private var notifyContinuation: CheckedContinuation<Void, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var frameContinuation: CheckedContinuation<Data, Error>?
    private var discoveryHandler: (@Sendable (DiscoveredBLEHost) -> Void)? = nil

    private let reassembler = BLEPacketFraming.Reassembler()
    private let lock = NSLock()

    public init(
        clientIdentity: CryptoIdentity,
        sequenceCounter: SequenceCounter = SequenceCounter()
    ) {
        self.clientIdentity = clientIdentity
        self.sequenceCounter = sequenceCounter
        self.queue = DispatchQueue(label: "com.handshake.ble.central", qos: .userInitiated)
        super.init()
    }

    // MARK: - Lock Helpers

    private func setScanContinuation(_ cont: CheckedContinuation<CBPeripheral, Error>?) {
        lock.lock()
        defer { lock.unlock() }
        scanContinuation = cont
    }

    private func takeScanContinuation() -> CheckedContinuation<CBPeripheral, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = scanContinuation
        scanContinuation = nil
        return c
    }

    private func setConnectContinuation(_ cont: CheckedContinuation<Void, Error>?) {
        lock.lock()
        defer { lock.unlock() }
        connectContinuation = cont
    }

    private func takeConnectContinuation() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = connectContinuation
        connectContinuation = nil
        return c
    }

    private func setCharDiscoveryContinuation(_ cont: CheckedContinuation<Void, Error>?) {
        lock.lock()
        defer { lock.unlock() }
        charDiscoveryContinuation = cont
    }

    private func takeCharDiscoveryContinuation() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = charDiscoveryContinuation
        charDiscoveryContinuation = nil
        return c
    }

    private func setNotifyContinuation(_ cont: CheckedContinuation<Void, Error>?) {
        lock.lock()
        defer { lock.unlock() }
        notifyContinuation = cont
    }

    private func takeNotifyContinuation() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = notifyContinuation
        notifyContinuation = nil
        return c
    }

    private func setWriteContinuation(_ cont: CheckedContinuation<Void, Error>?) {
        lock.lock()
        defer { lock.unlock() }
        writeContinuation = cont
    }

    private func takeWriteContinuation() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = writeContinuation
        writeContinuation = nil
        return c
    }

    private func setFrameContinuation(_ cont: CheckedContinuation<Data, Error>?) {
        lock.lock()
        defer { lock.unlock() }
        frameContinuation = cont
    }

    private func takeFrameContinuation() -> CheckedContinuation<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = frameContinuation
        frameContinuation = nil
        return c
    }

    private func setDiscoveryHandler(_ handler: (@Sendable (DiscoveredBLEHost) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        discoveryHandler = handler
    }

    private func getDiscoveryHandler() -> (@Sendable (DiscoveredBLEHost) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return discoveryHandler
    }

    // MARK: - Discovery & Connection

    /// Scans for nearby Mac companion devices advertising the Handshake GATT service.
    public func scanForNearbyHosts(
        timeoutSeconds: TimeInterval = 6.0,
        onDiscovered: @escaping @Sendable (DiscoveredBLEHost) -> Void
    ) async throws {
        self.centralManager = CBCentralManager(delegate: self, queue: queue)
        try await waitForPoweredOn(timeoutSeconds: 3.0)

        setDiscoveryHandler(onDiscovered)
        centralManager?.scanForPeripherals(withServices: [BLEConstants.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))

        setDiscoveryHandler(nil)
        centralManager?.stopScan()
    }

    /// Connects directly to an identified peripheral and discovers characteristics.
    public func connectToPeripheral(_ peripheral: CBPeripheral, timeoutSeconds: TimeInterval = 6.0) async throws {
        if self.centralManager == nil {
            self.centralManager = CBCentralManager(delegate: self, queue: queue)
        }
        try await waitForPoweredOn(timeoutSeconds: 2.5)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setConnectContinuation(continuation)
            self.lock.lock()
            self.connectedPeripheral = peripheral
            self.lock.unlock()

            peripheral.delegate = self
            centralManager?.connect(peripheral, options: nil)

            queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                guard let self = self else { return }
                if let cont = self.takeConnectContinuation() {
                    cont.resume(throwing: BLETransportError.connectionFailed("Connection timed out"))
                }
            }
        }

        try await discoverCharacteristicsAndSubscribe(on: peripheral, timeoutSeconds: timeoutSeconds)
    }

    /// Carries the mandatory QR-validated pairing invitation over Bluetooth LE.
    /// BLE discovery is used only to locate a transport; it never supplies pairing
    /// material or authenticates the Mac.
    public func pairOverBLE(
        peripheral: CBPeripheral,
        invitation: PairingInvitation,
        trustStore: TrustStore,
        timeoutSeconds: TimeInterval = 10.0,
        onStageChange: (@Sendable (PairingStage) -> Void)? = nil,
        onSASDerived: @escaping @Sendable (String) async -> Bool
    ) async throws -> TrustRecord {
        let endpointName = peripheral.name ?? "Mac Companion (BLE)"
        onStageChange?(.connectingSocket(endpoint: endpointName))

        // 1. Establish GATT connection and subscribe to notifications
        try await connectToPeripheral(peripheral, timeoutSeconds: timeoutSeconds)

        let channel = makeTransportChannel()

        guard !invitation.isExpired() else {
            throw PairingError.invitationExpired
        }

        // 2. Initialize from the invitation the user scanned from this Mac.
        onStageChange?(.exchangingEphemeralKeys)
        let clientSession = try ClientPairingSession(
            invitation: invitation,
            clientIdentity: self.clientIdentity
        )

        // 3. Send PairingRequest
        let request = await clientSession.createRequest()
        let reqData = try JSONEncoder().encode(request)
        try await channel.send(frameData: reqData)

        onStageChange?(.waitingForMacResponse)

        // 4. Receive PairingResponse
        let respBytes = try await channel.receive(timeoutSeconds: 15.0)

        // Check if Mac returned a rejection acknowledgment
        if let ack = try? JSONDecoder().decode(CommandAcknowledgment.self, from: respBytes) {
            let rejectionMsg: String
            if case .rejected(let reason) = ack.status {
                rejectionMsg = reason
            } else {
                rejectionMsg = "Pairing request was declined by the Mac."
            }
            throw PairingError.handshakeFailed(rejectionMsg)
        }

        let response = try JSONDecoder().decode(PairingResponse.self, from: respBytes)

        // 5. Process response & derive SAS code independently
        onStageChange?(.derivingVerificationCode)
        let sasCode = try await clientSession.processResponse(response)

        // 6. Request user explicit approval over derived SAS code
        onStageChange?(.waitingForMutualConfirmation(sasCode: sasCode))
        let approved = await onSASDerived(sasCode)
        guard approved else {
            let rejectConfirm = try await clientSession.createConfirmation(isApproved: false)
            let rejectData = try JSONEncoder().encode(rejectConfirm)
            try? await channel.send(frameData: rejectData)
            disconnect()
            onStageChange?(.pairingFailed(reason: "Pairing was rejected on this device."))
            throw PairingError.unapproved
        }

        // 7. Send approved PairingConfirmation
        onStageChange?(.sendingConfirmation)
        let confirmation = try await clientSession.createConfirmation(isApproved: true)
        let confirmData = try JSONEncoder().encode(confirmation)
        try await channel.send(frameData: confirmData)

        // 8. Receive PairingCompletion
        let compBytes = try await channel.receive(timeoutSeconds: 30.0)
        let completion = try JSONDecoder().decode(PairingCompletion.self, from: compBytes)
        guard completion.isSuccessful else {
            throw PairingError.handshakeFailed("Pairing was rejected on the Mac screen.")
        }

        // 9. Complete pairing and pin host in TrustStore
        let establishedRecord = try await clientSession.completePairing(completion, trustStore: trustStore)
        onStageChange?(.pairingCompleted(peer: invitation.hostIdentity))

        return establishedRecord
    }

    /// Discovers and connects to the Mac companion over Bluetooth Low Energy with timeout.
    public func discoverAndConnect(
        targetPeerPublicKeyHex: String? = nil,
        timeoutSeconds: TimeInterval = 5.0
    ) async throws -> CBPeripheral {
        self.centralManager = CBCentralManager(delegate: self, queue: queue)

        try await waitForPoweredOn(timeoutSeconds: 2.5)

        // 1. Scan for peripheral
        let peripheral = try await withCheckedThrowingContinuation { continuation in
            setScanContinuation(continuation)
            centralManager?.scanForPeripherals(withServices: [BLEConstants.serviceUUID], options: nil)

            queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                guard let self = self else { return }
                if let cont = self.takeScanContinuation() {
                    self.centralManager?.stopScan()
                    cont.resume(throwing: BLETransportError.scanningTimedOut)
                }
            }
        }

        // 2. Connect to discovered peripheral
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setConnectContinuation(continuation)
            self.lock.lock()
            self.connectedPeripheral = peripheral
            self.lock.unlock()

            peripheral.delegate = self
            centralManager?.connect(peripheral, options: nil)

            queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                guard let self = self else { return }
                if let cont = self.takeConnectContinuation() {
                    cont.resume(throwing: BLETransportError.connectionFailed("Connection timed out"))
                }
            }
        }

        // 3. Discover characteristics & subscribe to notifications
        try await discoverCharacteristicsAndSubscribe(on: peripheral, timeoutSeconds: timeoutSeconds)

        return peripheral
    }

    private func waitForPoweredOn(timeoutSeconds: TimeInterval) async throws {
        let start = Date()
        while let cm = centralManager, cm.state != .poweredOn {
            if cm.state == .poweredOff { throw BLETransportError.bluetoothPoweredOff }
            if cm.state == .unauthorized { throw BLETransportError.bluetoothUnauthorized }
            if cm.state == .unsupported { throw BLETransportError.bluetoothUnsupported }
            if Date().timeIntervalSince(start) > timeoutSeconds {
                throw BLETransportError.scanningTimedOut
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func discoverCharacteristicsAndSubscribe(on peripheral: CBPeripheral, timeoutSeconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setCharDiscoveryContinuation(continuation)
            peripheral.discoverServices([BLEConstants.serviceUUID])

            queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                guard let self = self else { return }
                if let cont = self.takeCharDiscoveryContinuation() {
                    cont.resume(throwing: BLETransportError.serviceNotFound)
                }
            }
        }

        guard let ack = ackChar else {
            throw BLETransportError.characteristicNotFound
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setNotifyContinuation(continuation)
            peripheral.setNotifyValue(true, for: ack)

            queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                guard let self = self else { return }
                if let cont = self.takeNotifyContinuation() {
                    cont.resume(throwing: BLETransportError.transferFailed("Notification subscription timed out"))
                }
            }
        }
    }

    // MARK: - Framed Transport Channel

    public func makeTransportChannel() -> HandshakeFramedTransport {
        BLEFramedChannel(client: self)
    }

    public func sendFrame(_ frame: Data) async throws {
        guard let peripheral = connectedPeripheral, let char = commandChar else {
            throw BLETransportError.characteristicNotFound
        }

        let maxWrite = min(peripheral.maximumWriteValueLength(for: .withResponse), 512)
        let chunks = try BLEPacketFraming.chunk(frame: frame, maxChunkSize: maxWrite)

        for chunk in chunks {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                setWriteContinuation(continuation)
                peripheral.writeValue(chunk, for: char, type: .withResponse)
            }
        }
    }

    public func receiveFrame(timeoutSeconds: TimeInterval? = 10.0) async throws -> Data {
        let timeout = timeoutSeconds ?? 10.0
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            setFrameContinuation(continuation)

            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self = self else { return }
                if let cont = self.takeFrameContinuation() {
                    cont.resume(throwing: BLETransportError.timeout)
                }
            }
        }
    }

    public func sendCommand(
        _ commandType: CommandType,
        to peripheral: CBPeripheral,
        trustedHost: DeviceIdentity,
        preSharedKeyHex: String? = nil,
        masterPSK: SymmetricKey? = nil,
        useFreshSession: Bool = true,
        onStateChange: (@Sendable (ConnectionState) -> Void)? = nil
    ) async throws -> CommandAcknowledgment {
        onStateChange?(.connectingSecurely)

        let channel = makeTransportChannel()

        // 1. Session handshake
        onStateChange?(.verifyingDevice)
        let sessionKey: SymmetricKey
        let nonceSalt: Data?

        if useFreshSession {
            let resolvedMasterPSK: SymmetricKey?
            if let masterPSK {
                resolvedMasterPSK = masterPSK
            } else if let hex = preSharedKeyHex, let pskData = Data(hexString: hex), pskData.count == 32 {
                resolvedMasterPSK = SymmetricKey(data: pskData)
            } else {
                resolvedMasterPSK = nil
            }

            let session = try await performBLESharesSessionHandshake(
                channel: channel,
                trustedHostPublicKeyHex: trustedHost.publicKeyHex,
                masterPSK: resolvedMasterPSK
            )
            sessionKey = session.clientToHostKey
            nonceSalt = session.clientToHostNonceSalt
            onStateChange?(.connected(transport: .bluetoothLE, peer: session.peer))
        } else {
            sessionKey = try SecureChannel.resolveSessionKey(preSharedKeyHex: preSharedKeyHex, role: .clientToHost)
            nonceSalt = nil
        }

        // 2. Prepare & seal CommandMessage
        let commandMessage = CommandMessage(command: commandType, timestamp: Date(), validityWindowSeconds: 30.0)
        let seq = await sequenceCounter.nextOutgoing()
        let envelope = try SecureChannel.seal(
            message: commandMessage,
            sequenceNumber: seq,
            senderIdentity: clientIdentity,
            recipientPublicKeyHex: trustedHost.publicKeyHex,
            sessionKey: sessionKey,
            nonceSalt: nonceSalt
        )

        // 3. Transmit envelope
        onStateChange?(.sendingCommand(commandType))
        let envelopeData = try JSONEncoder().encode(envelope)
        try await channel.send(frameData: envelopeData)

        onStateChange?(.executingCommand(commandType))

        // 4. Await signed acknowledgment
        let ackData = try await channel.receive(timeoutSeconds: 8.0)
        let ack = try JSONDecoder().decode(CommandAcknowledgment.self, from: ackData)

        // 5. Verify host signature
        guard let sigData = Data(hexString: ack.signatureHex),
              CryptoIdentity.verify(
                signatureRaw: sigData,
                for: ack.signablePayload,
                publicKeyHex: ack.hostIdentity.publicKeyHex
              ) else {
            onStateChange?(.commandFailed(reason: "Invalid Mac cryptographic signature over BLE"))
            throw BLETransportError.invalidAcknowledgment
        }

        // 6. Two-stage Sleep Handshake
        if commandType == .sleep && ack.status == .accepted {
            let receiptPlaceholder = CommandReceipt(commandId: commandMessage.id, clientIdentity: clientIdentity.identity)
            let sig = try clientIdentity.sign(data: receiptPlaceholder.signablePayload)
            let signedReceipt = CommandReceipt(
                commandId: commandMessage.id,
                timestampMilliseconds: receiptPlaceholder.timestampMilliseconds,
                clientIdentity: clientIdentity.identity,
                signatureHex: sig.hexString
            )
            let receiptData = try JSONEncoder().encode(signedReceipt)
            try await channel.send(frameData: receiptData)
        }

        onStateChange?(.commandCompleted(commandType))
        onStateChange?(.commandAccepted(commandType))
        return ack
    }

    private func performBLESharesSessionHandshake(
        channel: HandshakeFramedTransport,
        trustedHostPublicKeyHex: String,
        masterPSK: SymmetricKey?
    ) async throws -> EstablishedSession {
        guard let psk = masterPSK else {
            throw HandshakeClient.ClientError.connectionFailed("Pre-shared key missing or invalid (SEC-02)")
        }

        let clientEphemeralKey = P256.KeyAgreement.PrivateKey()
        let clientEphemeralHex = clientEphemeralKey.publicKey.rawRepresentation.hexString
        let sessionId = UUID()

        let placeholderInit = SessionInitiation(
            id: sessionId,
            clientIdentity: clientIdentity.identity,
            clientEphemeralPublicKeyHex: clientEphemeralHex
        )
        let clientSig = try clientIdentity.sign(data: placeholderInit.signablePayload)
        let sessionInit = SessionInitiation(
            id: sessionId,
            timestampMilliseconds: placeholderInit.timestampMilliseconds,
            clientIdentity: clientIdentity.identity,
            clientEphemeralPublicKeyHex: clientEphemeralHex,
            signatureHex: clientSig.hexString
        )

        let initData = try JSONEncoder().encode(sessionInit)
        try await channel.send(frameData: initData)

        let respData = try await channel.receive(timeoutSeconds: 5.0)
        let sessionResp = try JSONDecoder().decode(SessionResponse.self, from: respData)

        guard sessionResp.id == sessionId else {
            throw HandshakeClient.ClientError.invalidAcknowledgment
        }

        guard let hostSigData = Data(hexString: sessionResp.signatureHex),
              CryptoIdentity.verify(
                signatureRaw: hostSigData,
                for: sessionResp.signablePayload,
                publicKeyHex: trustedHostPublicKeyHex
              ) else {
            throw HandshakeClient.ClientError.invalidAcknowledgment
        }

        guard let hostEphemeralBytes = Data(hexString: sessionResp.hostEphemeralPublicKeyHex),
              let hostEphemeralKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: hostEphemeralBytes) else {
            throw HandshakeClient.ClientError.connectionFailed("Invalid host ephemeral public key")
        }

        let sharedSecret = try clientEphemeralKey.sharedSecretFromKeyAgreement(with: hostEphemeralKey)
        var transcript = sessionInit.signablePayload
        transcript.append(sessionResp.signablePayload)

        let keys = SessionKeyDerivation.deriveKeys(
            sharedSecret: sharedSecret,
            sessionId: sessionId,
            transcript: transcript,
            masterPSK: psk
        )

        return EstablishedSession(
            sessionId: sessionId,
            peer: sessionResp.hostIdentity,
            clientToHostKey: keys.clientToHostKey,
            hostToClientKey: keys.hostToClientKey,
            clientToHostNonceSalt: keys.clientNonceSalt,
            hostToClientNonceSalt: keys.hostNonceSalt
        )
    }

    public func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        if let p = connectedPeripheral, let cm = centralManager {
            cm.cancelPeripheralConnection(p)
        }
        connectedPeripheral = nil
        commandChar = nil
        ackChar = nil
        reassembler.reset()
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("[BLECentralClient] CBCentralManager state updated: \(central.state.rawValue)")
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Mac"
        print("[BLECentralClient] Discovered Handshake peripheral: '\(name)' (\(peripheral.identifier)), RSSI: \(RSSI)")

        let host = DiscoveredBLEHost(peripheral: peripheral, name: name, rssi: RSSI.intValue)
        getDiscoveryHandler()?(host)

        if let cont = takeScanContinuation() {
            central.stopScan()
            cont.resume(returning: peripheral)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[BLECentralClient] Connected to peripheral: \(peripheral.identifier)")
        takeConnectContinuation()?.resume()
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[BLECentralClient] Failed to connect to peripheral: \(error?.localizedDescription ?? "unknown error")")
        takeConnectContinuation()?.resume(throwing: BLETransportError.connectionFailed(error?.localizedDescription ?? "Failed to connect"))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[BLECentralClient] Peripheral disconnected: \(peripheral.identifier), error=\(String(describing: error))")
        let cont = takeFrameContinuation()
        lock.lock()
        connectedPeripheral = nil
        commandChar = nil
        ackChar = nil
        reassembler.reset()
        lock.unlock()
        cont?.resume(throwing: BLETransportError.disconnected)
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("[BLECentralClient] Failed to discover services: \(error.localizedDescription)")
            takeCharDiscoveryContinuation()?.resume(throwing: error)
            return
        }

        guard let services = peripheral.services,
              let service = services.first(where: { $0.uuid == BLEConstants.serviceUUID }) else {
            print("[BLECentralClient] Target service \(BLEConstants.serviceUUIDString) not found on peripheral")
            takeCharDiscoveryContinuation()?.resume(throwing: BLETransportError.serviceNotFound)
            return
        }

        print("[BLECentralClient] Target service discovered. Discovering characteristics...")
        peripheral.discoverCharacteristics([BLEConstants.commandCharacteristicUUID, BLEConstants.ackCharacteristicUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("[BLECentralClient] Error discovering characteristics: \(error.localizedDescription)")
            takeCharDiscoveryContinuation()?.resume(throwing: error)
            return
        }

        guard let chars = service.characteristics else {
            takeCharDiscoveryContinuation()?.resume(throwing: BLETransportError.characteristicNotFound)
            return
        }

        for char in chars {
            if char.uuid == BLEConstants.commandCharacteristicUUID {
                self.commandChar = char
            } else if char.uuid == BLEConstants.ackCharacteristicUUID {
                self.ackChar = char
            }
        }

        print("[BLECentralClient] Characteristics discovered: commandChar=\(commandChar != nil), ackChar=\(ackChar != nil)")
        if commandChar != nil && ackChar != nil {
            takeCharDiscoveryContinuation()?.resume()
        } else {
            takeCharDiscoveryContinuation()?.resume(throwing: BLETransportError.characteristicNotFound)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("[BLECentralClient] Notification subscription error: \(error.localizedDescription)")
            takeNotifyContinuation()?.resume(throwing: error)
        } else {
            print("[BLECentralClient] Notification subscription active on characteristic \(characteristic.uuid)")
            takeNotifyContinuation()?.resume()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            takeWriteContinuation()?.resume(throwing: BLETransportError.transferFailed(error.localizedDescription))
        } else {
            takeWriteContinuation()?.resume()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BLEConstants.ackCharacteristicUUID, let data = characteristic.value else { return }

        do {
            if let frame = try reassembler.processChunk(data) {
                takeFrameContinuation()?.resume(returning: frame)
            }
        } catch {
            takeFrameContinuation()?.resume(throwing: error)
        }
    }
}

// MARK: - BLE Framed Channel

private final class BLEFramedChannel: HandshakeFramedTransport, @unchecked Sendable {
    let transportType: TransportType = .bluetoothLE
    private let client: BLECentralClient

    init(client: BLECentralClient) {
        self.client = client
    }

    func send(frameData: Data) async throws {
        try await client.sendFrame(frameData)
    }

    func receive(timeoutSeconds: TimeInterval? = nil) async throws -> Data {
        try await client.receiveFrame(timeoutSeconds: timeoutSeconds)
    }

    func close() async {
        client.disconnect()
    }
}
