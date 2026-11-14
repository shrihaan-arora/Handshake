import XCTest
import CoreBluetooth
@testable import HandshakeCore

final class BLETransportTests: XCTestCase {

    func testBLEConstantsUUIDs() {
        XCTAssertEqual(BLEConstants.serviceUUID.uuidString, "A67D5894-0409-411B-8233-000000000001")
        XCTAssertEqual(BLEConstants.commandCharacteristicUUID.uuidString, "A67D5894-0409-411B-8233-000000000002")
        XCTAssertEqual(BLEConstants.ackCharacteristicUUID.uuidString, "A67D5894-0409-411B-8233-000000000003")
        XCTAssertEqual(BLEConstants.maxChunkSize, 180)
    }

    func testBLETransportErrorDescriptions() {
        let poweredOff = BLETransportError.bluetoothPoweredOff
        let unauthorized = BLETransportError.bluetoothUnauthorized
        let unsupported = BLETransportError.bluetoothUnsupported
        let timedOut = BLETransportError.scanningTimedOut
        let invalidAck = BLETransportError.invalidAcknowledgment

        XCTAssertTrue(poweredOff.localizedDescription.contains("Bluetooth is turned off"))
        XCTAssertTrue(unauthorized.localizedDescription.contains("permission has not been granted"))
        XCTAssertTrue(unsupported.localizedDescription.contains("not supported"))
        XCTAssertTrue(timedOut.localizedDescription.contains("timed out"))
        XCTAssertTrue(invalidAck.localizedDescription.contains("digital signature"))
    }
}
