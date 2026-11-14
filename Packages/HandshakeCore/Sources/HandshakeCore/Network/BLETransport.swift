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
        }
    }
}

// MARK: - BLE Peripheral Host (Mac Companion)

#if os(macOS)
/// Mac companion BLE peripheral host that advertises and processes incoming commands over BLE.
/// Operates strictly within the foreground main-window lifecycle.
public final class BLEPeripheralHost: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {

    public typealias CommandHandler = @Sendable (CommandMessage, DeviceIdentity) async -> CommandAcknowledgment.ExecutionStatus

    private let hostIdentity: CryptoIdentity
    private let trustStore: TrustStore
    private let sequenceCounter: SequenceCounter
    private let commandHandler: CommandHandler

    private var peripheralManager: CBPeripheralManager?
    private var commandChar: CBMutableCharacteristic?
    private var ackChar: CBMutableCharacteristic?
    private var inboundBuffer = Data()
    private let lock = NSLock()
    private var isAdvertising: Bool = false

    public init(
        hostIdentity: CryptoIdentity,
        trustStore: TrustStore,
        sequenceCounter: SequenceCounter = SequenceCounter(),
        commandHandler: @escaping CommandHandler
    ) {
        self.hostIdentity = hostIdentity
        self.trustStore = trustStore
        self.sequenceCounter = sequenceCounter
        self.commandHandler = commandHandler
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
    }

    public var advertising: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isAdvertising
    }

    // MARK: - CBPeripheralManagerDelegate

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            setupServices(peripheral)
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

        peripheral.add(service)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { return }
        let advertisementData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [BLEConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: hostIdentity.identity.displayName
        ]
        peripheral.startAdvertising(advertisementData)
        lock.lock()
        isAdvertising = true
        lock.unlock()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == BLEConstants.commandCharacteristicUUID, let data = request.value {
                lock.lock()
                inboundBuffer.append(data)
                let currentData = inboundBuffer
                lock.unlock()

                // Check if buffer contains a complete 4-byte framed message
                if currentData.count >= 4 {
                    let frameLen = Int(currentData[0]) << 24 | Int(currentData[1]) << 16 | Int(currentData[2]) << 8 | Int(currentData[3])
                    if currentData.count >= 4 + frameLen {
                        let packetData = currentData.subdata(in: 4..<(4 + frameLen))
                        lock.lock()
                        inboundBuffer.removeSubrange(0..<(4 + frameLen))
                        lock.unlock()

                        Task {
                            await processPacket(packetData, central: request.central)
                        }
                    }
                }
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }

    private func processPacket(_ rawData: Data, central: CBCentral) async {
        do {
            let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: rawData)

            guard let trustRecord = await trustStore.getRecord(publicKeyHex: envelope.senderPublicKeyHex), !trustRecord.isRevoked else {
                return
            }

            let senderKeyData = Data(hexString: envelope.senderPublicKeyHex) ?? Data()
            let sessionKey = SymmetricKey(data: SHA256.hash(data: senderKeyData))

            let message = try await SecureChannel.open(
                envelope: envelope,
                sessionKey: sessionKey,
                trustedSenderPublicKeyHex: trustRecord.peer.publicKeyHex,
                sequenceCounter: sequenceCounter
            )

            guard trustRecord.authorizedCapabilities.contains(message.command) else {
                return
            }

            try? await trustStore.updateLastSeen(id: trustRecord.id)
            let status = await commandHandler(message, trustRecord.peer)

            // Make signed ack
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
            var framedAck = Data()
            var length = UInt32(ackData.count).bigEndian
            framedAck.append(Data(bytes: &length, count: 4))
            framedAck.append(ackData)

            if let ackChar = self.ackChar, let manager = self.peripheralManager {
                manager.updateValue(framedAck, for: ackChar, onSubscribedCentrals: [central])
            }

            if message.command == .sleep, case .executed = status {
                try? await Task.sleep(nanoseconds: 200_000_000)
                _ = MacSleepEngine().triggerSleep()
            }
        } catch {
            // Drop invalid/unauthenticated frames
        }
    }
}
#endif

// MARK: - BLE Central Client (iPhone)

/// iPhone BLE central client that scans for Mac companion, sends framed commands, and receives signed acks.
public final class BLECentralClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {

    private let clientIdentity: CryptoIdentity
    private let sequenceCounter: SequenceCounter

    private var centralManager: CBCentralManager?
    private var targetPeripheral: CBPeripheral?
    private var commandChar: CBCharacteristic?
    private var ackChar: CBCharacteristic?

    private var scanContinuation: CheckedContinuation<CBPeripheral, Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var ackContinuation: CheckedContinuation<CommandAcknowledgment, Error>?
    private var inboundAckData = Data()
    private let lock = NSLock()

    public init(
        clientIdentity: CryptoIdentity,
        sequenceCounter: SequenceCounter = SequenceCounter()
    ) {
        self.clientIdentity = clientIdentity
        self.sequenceCounter = sequenceCounter
        super.init()
    }

    /// Discovers and connects to the Mac companion over Bluetooth Low Energy with timeout.
    public func discoverAndConnect(timeoutSeconds: TimeInterval = 4.0) async throws -> CBPeripheral {
        let queue = DispatchQueue(label: "com.handshake.ble.central", qos: .userInitiated)
        self.centralManager = CBCentralManager(delegate: self, queue: queue)

        // Wait for Bluetooth powered on
        try await waitForPoweredOn(timeoutSeconds: 2.0)

        // Scan for peripheral
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.scanContinuation = continuation
            lock.unlock()

            centralManager?.scanForPeripherals(withServices: [BLEConstants.serviceUUID], options: nil)

            queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                if let cont = self.scanContinuation {
                    self.scanContinuation = nil
                    self.centralManager?.stopScan()
                    cont.resume(throwing: BLETransportError.scanningTimedOut)
                }
                self.lock.unlock()
            }
        }
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

    /// Transmits an authenticated command envelope over BLE and awaits signed acknowledgment.
    public func sendCommand(
        _ commandType: CommandType,
        to peripheral: CBPeripheral,
        trustedHostPublicKeyHex: String
    ) async throws -> CommandAcknowledgment {
        self.targetPeripheral = peripheral
        peripheral.delegate = self

        // 1. Seal envelope
        let message = CommandMessage(command: commandType, timestamp: Date(), validityWindowSeconds: 30.0)
        let seq = await sequenceCounter.nextOutgoing()
        let senderKeyData = Data(hexString: clientIdentity.identity.publicKeyHex) ?? Data()
        let sessionKey = SymmetricKey(data: SHA256.hash(data: senderKeyData))

        let envelope = try SecureChannel.seal(
            message: message,
            sequenceNumber: seq,
            senderIdentity: clientIdentity,
            recipientPublicKeyHex: trustedHostPublicKeyHex,
            sessionKey: sessionKey
        )

        let envelopeData = try JSONEncoder().encode(envelope)
        var framedData = Data()
        var length = UInt32(envelopeData.count).bigEndian
        framedData.append(Data(bytes: &length, count: 4))
        framedData.append(envelopeData)

        // 2. Discover service & characteristics if needed
        peripheral.discoverServices([BLEConstants.serviceUUID])

        // 3. Await acknowledgment
        let payload = framedData
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.ackContinuation = continuation
            lock.unlock()

            // Transmit chunks
            Task {
                do {
                    try await self.writeFramedData(payload, to: peripheral)
                } catch {
                    self.takeAckContinuation()?.resume(throwing: error)
                }
            }
        }
    }

    private func takeAckContinuation() -> CheckedContinuation<CommandAcknowledgment, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let cont = ackContinuation
        ackContinuation = nil
        return cont
    }

    private func writeFramedData(_ data: Data, to peripheral: CBPeripheral) async throws {
        // Wait up to 3s for characteristics
        var waited = 0
        while commandChar == nil && waited < 30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        guard let char = commandChar else {
            throw BLETransportError.characteristicNotFound
        }

        var offset = 0
        while offset < data.count {
            let chunkSize = min(BLEConstants.maxChunkSize, data.count - offset)
            let chunk = data.subdata(in: offset..<(offset + chunkSize))
            peripheral.writeValue(chunk, for: char, type: .withResponse)
            offset += chunkSize
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms pacing
        }
    }

    public func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        if let p = targetPeripheral, let cm = centralManager {
            cm.cancelPeripheralConnection(p)
        }
        targetPeripheral = nil
        commandChar = nil
        ackChar = nil
        inboundAckData.removeAll()
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // State updates handled reactively
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        lock.lock()
        if let cont = scanContinuation {
            scanContinuation = nil
            central.stopScan()
            cont.resume(returning: peripheral)
        }
        lock.unlock()
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([BLEConstants.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lock.lock()
        if let cont = connectContinuation {
            connectContinuation = nil
            cont.resume(throwing: BLETransportError.connectionFailed(error?.localizedDescription ?? "Unknown error"))
        }
        lock.unlock()
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == BLEConstants.serviceUUID {
            peripheral.discoverCharacteristics([BLEConstants.commandCharacteristicUUID, BLEConstants.ackCharacteristicUUID], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for char in chars {
            if char.uuid == BLEConstants.commandCharacteristicUUID {
                self.commandChar = char
            } else if char.uuid == BLEConstants.ackCharacteristicUUID {
                self.ackChar = char
                peripheral.setNotifyValue(true, for: char)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BLEConstants.ackCharacteristicUUID, let data = characteristic.value else { return }

        lock.lock()
        inboundAckData.append(data)
        let current = inboundAckData
        lock.unlock()

        if current.count >= 4 {
            let frameLen = Int(current[0]) << 24 | Int(current[1]) << 16 | Int(current[2]) << 8 | Int(current[3])
            if current.count >= 4 + frameLen {
                let packetData = current.subdata(in: 4..<(4 + frameLen))
                lock.lock()
                inboundAckData.removeSubrange(0..<(4 + frameLen))
                let cont = ackContinuation
                ackContinuation = nil
                lock.unlock()

                if let cont = cont {
                    do {
                        let ack = try JSONDecoder().decode(CommandAcknowledgment.self, from: packetData)
                        cont.resume(returning: ack)
                    } catch {
                        cont.resume(throwing: BLETransportError.invalidAcknowledgment)
                    }
                }
            }
        }
    }
}
