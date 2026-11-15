import Foundation
import SQLite3

public struct PairingEventRecord: Identifiable, Sendable, Equatable {
    public let id: Int64?
    public let peerDeviceId: String
    public let peerDeviceName: String?
    public let eventType: String
    public let occurredAt: String
    public let result: String
    public let protocolVersion: String?

    public init(
        id: Int64? = nil,
        peerDeviceId: String,
        peerDeviceName: String? = nil,
        eventType: String,
        occurredAt: String = DatabaseManager.iso8601String(),
        result: String,
        protocolVersion: String? = "1.0"
    ) {
        self.id = id
        self.peerDeviceId = peerDeviceId
        self.peerDeviceName = peerDeviceName
        self.eventType = eventType
        self.occurredAt = occurredAt
        self.result = result
        self.protocolVersion = protocolVersion
    }
}

/// Repository for inserting and querying pairing lifecycle audit events.
public final class PairingEventRepository: @unchecked Sendable {

    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    @discardableResult
    public func insert(_ event: PairingEventRecord) throws -> Int64 {
        try dbManager.runWithLock { db in
            let sql = """
            INSERT INTO pairing_events (
                peer_device_id, peer_device_name, event_type,
                occurred_at, result, protocol_version
            ) VALUES (?, ?, ?, ?, ?, ?);
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, index: 1, value: event.peerDeviceId)
            bindOptionalText(stmt, index: 2, value: event.peerDeviceName)
            bindText(stmt, index: 3, value: event.eventType)
            bindText(stmt, index: 4, value: event.occurredAt)
            bindText(stmt, index: 5, value: event.result)
            bindOptionalText(stmt, index: 6, value: event.protocolVersion)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func fetchRecent(limit: Int = 100) throws -> [PairingEventRecord] {
        try dbManager.runWithLock { db in
            let sql = """
            SELECT id, peer_device_id, peer_device_name, event_type,
                   occurred_at, result, protocol_version
            FROM pairing_events
            ORDER BY occurred_at DESC, id DESC
            LIMIT ?;
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(limit))

            var results: [PairingEventRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let peerDeviceId = String(cString: sqlite3_column_text(stmt, 1))
                let peerDeviceName = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let eventType = String(cString: sqlite3_column_text(stmt, 3))
                let occurredAt = String(cString: sqlite3_column_text(stmt, 4))
                let result = String(cString: sqlite3_column_text(stmt, 5))
                let protocolVersion = sqlite3_column_text(stmt, 6).map { String(cString: $0) }

                results.append(PairingEventRecord(
                    id: id,
                    peerDeviceId: peerDeviceId,
                    peerDeviceName: peerDeviceName,
                    eventType: eventType,
                    occurredAt: occurredAt,
                    result: result,
                    protocolVersion: protocolVersion
                ))
            }
            return results
        }
    }

    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        if let val = value {
            sqlite3_bind_text(stmt, index, (val as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
