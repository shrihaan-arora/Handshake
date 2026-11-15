import Foundation
import SQLite3

public struct CommandLogRecord: Identifiable, Sendable, Equatable {
    public let id: Int64?
    public let requestId: String
    public let peerDeviceId: String
    public let peerDeviceName: String?
    public let commandType: String
    public let receivedAt: String
    public let executionStartedAt: String?
    public let completedAt: String?
    public let status: String
    public let resultCode: String?
    public let errorMessage: String?
    public let protocolVersion: String?

    public init(
        id: Int64? = nil,
        requestId: String,
        peerDeviceId: String,
        peerDeviceName: String? = nil,
        commandType: String,
        receivedAt: String = DatabaseManager.iso8601String(),
        executionStartedAt: String? = nil,
        completedAt: String? = nil,
        status: String,
        resultCode: String? = nil,
        errorMessage: String? = nil,
        protocolVersion: String? = "1.0"
    ) {
        self.id = id
        self.requestId = requestId
        self.peerDeviceId = peerDeviceId
        self.peerDeviceName = peerDeviceName
        self.commandType = commandType
        self.receivedAt = receivedAt
        self.executionStartedAt = executionStartedAt
        self.completedAt = completedAt
        self.status = status
        self.resultCode = resultCode
        self.errorMessage = errorMessage
        self.protocolVersion = protocolVersion
    }
}

/// Repository for inserting, updating, and querying command audit logs
/// using parameterized SQL statements to eliminate SQL injection vulnerabilities.
public final class CommandLogRepository: @unchecked Sendable {

    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    // MARK: - Insert

    @discardableResult
    public func insert(_ record: CommandLogRecord) throws -> Int64 {
        try dbManager.runWithLock { db in
            let sql = """
            INSERT INTO command_logs (
                request_id, peer_device_id, peer_device_name, command_type,
                received_at, execution_started_at, completed_at, status,
                result_code, error_message, protocol_version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, index: 1, value: record.requestId)
            bindText(stmt, index: 2, value: record.peerDeviceId)
            bindOptionalText(stmt, index: 3, value: record.peerDeviceName)
            bindText(stmt, index: 4, value: record.commandType)
            bindText(stmt, index: 5, value: record.receivedAt)
            bindOptionalText(stmt, index: 6, value: record.executionStartedAt)
            bindOptionalText(stmt, index: 7, value: record.completedAt)
            bindText(stmt, index: 8, value: record.status)
            bindOptionalText(stmt, index: 9, value: record.resultCode)
            bindOptionalText(stmt, index: 10, value: record.errorMessage)
            bindOptionalText(stmt, index: 11, value: record.protocolVersion)

            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE {
                return sqlite3_last_insert_rowid(db)
            } else if step == SQLITE_CONSTRAINT {
                throw DatabaseError.constraintViolation(String(cString: sqlite3_errmsg(db)))
            } else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    // MARK: - Update Lifecycle

    public func markExecutionStarted(requestId: String, startedAt: String = DatabaseManager.iso8601String()) throws {
        try dbManager.runWithLock { db in
            let sql = "UPDATE command_logs SET execution_started_at = ?, status = 'executing' WHERE request_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, index: 1, value: startedAt)
            bindText(stmt, index: 2, value: requestId)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func updateCompletion(
        requestId: String,
        status: String,
        completedAt: String = DatabaseManager.iso8601String(),
        resultCode: String? = nil,
        errorMessage: String? = nil
    ) throws {
        try dbManager.runWithLock { db in
            let sql = """
            UPDATE command_logs
            SET status = ?, completed_at = ?, result_code = ?, error_message = ?
            WHERE request_id = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, index: 1, value: status)
            bindText(stmt, index: 2, value: completedAt)
            bindOptionalText(stmt, index: 3, value: resultCode)
            bindOptionalText(stmt, index: 4, value: errorMessage)
            bindText(stmt, index: 5, value: requestId)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    // MARK: - Query

    public func fetchRecent(limit: Int = 100) throws -> [CommandLogRecord] {
        try dbManager.runWithLock { db in
            let sql = """
            SELECT id, request_id, peer_device_id, peer_device_name, command_type,
                   received_at, execution_started_at, completed_at, status,
                   result_code, error_message, protocol_version
            FROM command_logs
            ORDER BY received_at DESC, id DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(limit))

            var results: [CommandLogRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(readRecord(stmt: stmt!))
            }
            return results
        }
    }

    public func fetchByRequestId(_ requestId: String) throws -> CommandLogRecord? {
        try dbManager.runWithLock { db in
            let sql = """
            SELECT id, request_id, peer_device_id, peer_device_name, command_type,
                   received_at, execution_started_at, completed_at, status,
                   result_code, error_message, protocol_version
            FROM command_logs
            WHERE request_id = ?
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, index: 1, value: requestId)

            if sqlite3_step(stmt) == SQLITE_ROW {
                return readRecord(stmt: stmt!)
            }
            return nil
        }
    }

    public func fetchByPeer(peerDeviceId: String, limit: Int = 50) throws -> [CommandLogRecord] {
        try dbManager.runWithLock { db in
            let sql = """
            SELECT id, request_id, peer_device_id, peer_device_name, command_type,
                   received_at, execution_started_at, completed_at, status,
                   result_code, error_message, protocol_version
            FROM command_logs
            WHERE peer_device_id = ?
            ORDER BY received_at DESC, id DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, index: 1, value: peerDeviceId)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var results: [CommandLogRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(readRecord(stmt: stmt!))
            }
            return results
        }
    }

    // MARK: - Private Parameter Binding Helpers

    private func readRecord(stmt: OpaquePointer) -> CommandLogRecord {
        let id = sqlite3_column_int64(stmt, 0)
        let requestId = String(cString: sqlite3_column_text(stmt, 1))
        let peerDeviceId = String(cString: sqlite3_column_text(stmt, 2))
        let peerDeviceName = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
        let commandType = String(cString: sqlite3_column_text(stmt, 4))
        let receivedAt = String(cString: sqlite3_column_text(stmt, 5))
        let executionStartedAt = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
        let completedAt = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        let status = String(cString: sqlite3_column_text(stmt, 8))
        let resultCode = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
        let errorMessage = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
        let protocolVersion = sqlite3_column_text(stmt, 11).map { String(cString: $0) }

        return CommandLogRecord(
            id: id,
            requestId: requestId,
            peerDeviceId: peerDeviceId,
            peerDeviceName: peerDeviceName,
            commandType: commandType,
            receivedAt: receivedAt,
            executionStartedAt: executionStartedAt,
            completedAt: completedAt,
            status: status,
            resultCode: resultCode,
            errorMessage: errorMessage,
            protocolVersion: protocolVersion
        )
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
