import Foundation
import SQLite3

public struct DeviceSessionRecord: Identifiable, Sendable, Equatable {
    public let id: Int64?
    public let peerDeviceId: String
    public let sessionStartedAt: String
    public let sessionEndedAt: String?
    public let status: String

    public init(
        id: Int64? = nil,
        peerDeviceId: String,
        sessionStartedAt: String = DatabaseManager.iso8601String(),
        sessionEndedAt: String? = nil,
        status: String = "active"
    ) {
        self.id = id
        self.peerDeviceId = peerDeviceId
        self.sessionStartedAt = sessionStartedAt
        self.sessionEndedAt = sessionEndedAt
        self.status = status
    }
}

/// Repository for inserting, updating, and querying device transport sessions.
public final class DeviceSessionRepository: @unchecked Sendable {

    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    @discardableResult
    public func insert(_ session: DeviceSessionRecord) throws -> Int64 {
        try dbManager.runWithLock { db in
            let sql = """
            INSERT INTO device_sessions (
                peer_device_id, session_started_at, session_ended_at, status
            ) VALUES (?, ?, ?, ?);
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, index: 1, value: session.peerDeviceId)
            bindText(stmt, index: 2, value: session.sessionStartedAt)
            bindOptionalText(stmt, index: 3, value: session.sessionEndedAt)
            bindText(stmt, index: 4, value: session.status)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func endSession(
        id: Int64,
        endedAt: String = DatabaseManager.iso8601String(),
        status: String = "closed"
    ) throws {
        try dbManager.runWithLock { db in
            let sql = "UPDATE device_sessions SET session_ended_at = ?, status = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, index: 1, value: endedAt)
            bindText(stmt, index: 2, value: status)
            sqlite3_bind_int64(stmt, 3, id)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func endActiveSessions(
        peerDeviceId: String,
        endedAt: String = DatabaseManager.iso8601String(),
        status: String = "closed"
    ) throws {
        try dbManager.runWithLock { db in
            let sql = "UPDATE device_sessions SET session_ended_at = ?, status = ? WHERE peer_device_id = ? AND session_ended_at IS NULL;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, index: 1, value: endedAt)
            bindText(stmt, index: 2, value: status)
            bindText(stmt, index: 3, value: peerDeviceId)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func fetchRecent(limit: Int = 100) throws -> [DeviceSessionRecord] {
        try dbManager.runWithLock { db in
            let sql = """
            SELECT id, peer_device_id, session_started_at, session_ended_at, status
            FROM device_sessions
            ORDER BY session_started_at DESC, id DESC
            LIMIT ?;
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(limit))

            var results: [DeviceSessionRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let peerDeviceId = String(cString: sqlite3_column_text(stmt, 1))
                let startedAt = String(cString: sqlite3_column_text(stmt, 2))
                let endedAt = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let status = String(cString: sqlite3_column_text(stmt, 4))

                results.append(DeviceSessionRecord(
                    id: id,
                    peerDeviceId: peerDeviceId,
                    sessionStartedAt: startedAt,
                    sessionEndedAt: endedAt,
                    status: status
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
