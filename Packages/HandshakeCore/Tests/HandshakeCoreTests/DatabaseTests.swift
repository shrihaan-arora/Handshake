import XCTest
import SQLite3
@testable import HandshakeCore

final class DatabaseTests: XCTestCase {

    private var tempDirectory: URL!
    private var tempDatabasePath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HandshakeTests-\(UUID().uuidString)", isDirectory: true)
        tempDatabasePath = tempDirectory.appendingPathComponent("test_handshake.sqlite").path
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDirectory.path) {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - 1. Database Creation & Permissions

    func test01_DatabaseCreationAndPermissions() throws {
        let dbManager = try DatabaseManager(path: tempDatabasePath)
        XCTAssertTrue(dbManager.isOpen)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDatabasePath))

        // POSIX directory permissions should be 0700 (user rwx only)
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: tempDirectory.path)
        if let permissions = dirAttributes[.posixPermissions] as? NSNumber {
            XCTAssertEqual(permissions.intValue & 0o777, 0o700, "Directory permissions must be strictly 0700")
        }

        // POSIX file permissions should be 0600 (user rw only)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: tempDatabasePath)
        if let permissions = fileAttributes[.posixPermissions] as? NSNumber {
            XCTAssertEqual(permissions.intValue & 0o777, 0o600, "Database file permissions must be strictly 0600")
        }

        dbManager.close()
        XCTAssertFalse(dbManager.isOpen)
    }

    // MARK: - 2. WAL Mode & PRAGMAs

    func test02_WALModeAndForeignKeys() throws {
        let dbManager = try DatabaseManager(path: tempDatabasePath)
        defer { dbManager.close() }

        try dbManager.runWithLock { db in
            // Verify Foreign Keys
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA foreign_keys;", -1, &stmt, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            let foreignKeys = sqlite3_column_int(stmt, 0)
            sqlite3_finalize(stmt)
            XCTAssertEqual(foreignKeys, 1, "foreign_keys PRAGMA must be enabled (1)")

            // Verify WAL journal mode
            XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA journal_mode;", -1, &stmt, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            let journalMode = String(cString: sqlite3_column_text(stmt, 0))
            sqlite3_finalize(stmt)
            XCTAssertEqual(journalMode.lowercased(), "wal", "journal_mode PRAGMA must be WAL")
        }
    }

    // MARK: - 3. Schema Migration

    func test03_SchemaMigrationV1() throws {
        let dbManager = try DatabaseManager(path: tempDatabasePath)
        defer { dbManager.close() }

        try dbManager.runWithLock { db in
            // Schema user_version should be 1
            let version = DatabaseMigrationManager.currentVersion(db: db)
            XCTAssertEqual(version, 1, "Schema version must be 1 after migration")

            // Verify tables exist
            let expectedTables = ["command_logs", "pairing_events", "device_sessions"]
            for table in expectedTables {
                var stmt: OpaquePointer?
                let sql = "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?;"
                XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
                sqlite3_bind_text(stmt, 1, (table as NSString).utf8String, -1, nil)
                XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
                let count = sqlite3_column_int(stmt, 0)
                sqlite3_finalize(stmt)
                XCTAssertEqual(count, 1, "Table \(table) must exist in database")
            }

            // Verify indices exist
            let expectedIndices = [
                "idx_command_logs_received_at",
                "idx_command_logs_peer",
                "idx_pairing_events_occurred_at",
                "idx_device_sessions_peer"
            ]
            for indexName in expectedIndices {
                var stmt: OpaquePointer?
                let sql = "SELECT count(*) FROM sqlite_master WHERE type='index' AND name=?;"
                XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
                sqlite3_bind_text(stmt, 1, (indexName as NSString).utf8String, -1, nil)
                XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
                let count = sqlite3_column_int(stmt, 0)
                sqlite3_finalize(stmt)
                XCTAssertEqual(count, 1, "Index \(indexName) must exist in database")
            }
        }
    }

    // MARK: - 4. Command Logs Insert & Query

    func test04_CommandLogInsertAndQueries() throws {
        let dbManager = try DatabaseManager(path: tempDatabasePath)
        defer { dbManager.close() }
        let repo = CommandLogRepository(dbManager: dbManager)

        let peerId = UUID().uuidString
        let req1 = UUID().uuidString
        let req2 = UUID().uuidString

        let record1 = CommandLogRecord(
            requestId: req1,
            peerDeviceId: peerId,
            peerDeviceName: "iPhone 16e",
            commandType: "LOCK_MAC",
            receivedAt: "2026-11-15T10:00:00.000Z",
            status: "executed",
            resultCode: "SUCCESS",
            errorMessage: nil,
            protocolVersion: "1.0"
        )
        let rowId1 = try repo.insert(record1)
        XCTAssertGreaterThan(rowId1, 0)

        let record2 = CommandLogRecord(
            requestId: req2,
            peerDeviceId: peerId,
            peerDeviceName: "iPhone 16e",
            commandType: "SLEEP_MAC",
            receivedAt: "2026-11-15T10:05:00.000Z",
            status: "failed",
            resultCode: "ERROR",
            errorMessage: "Display sleep timeout",
            protocolVersion: "1.0"
        )
        let rowId2 = try repo.insert(record2)
        XCTAssertGreaterThan(rowId2, rowId1)

        // Query Recent (ordered by received_at DESC)
        let recent = try repo.fetchRecent(limit: 10)
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent[0].requestId, req2)
        XCTAssertEqual(recent[1].requestId, req1)

        // Query by Request ID
        let fetchedReq1 = try repo.fetchByRequestId(req1)
        XCTAssertNotNil(fetchedReq1)
        XCTAssertEqual(fetchedReq1?.commandType, "LOCK_MAC")
        XCTAssertEqual(fetchedReq1?.peerDeviceName, "iPhone 16e")
        XCTAssertEqual(fetchedReq1?.status, "executed")

        // Query by Peer
        let peerLogs = try repo.fetchByPeer(peerDeviceId: peerId, limit: 10)
        XCTAssertEqual(peerLogs.count, 2)
    }

    // MARK: - 5. Command Log Execution Lifecycle Updates

    func test05_CommandLogExecutionLifecycleUpdates() throws {
        let dbManager = try DatabaseManager(path: tempDatabasePath)
        defer { dbManager.close() }
        let repo = CommandLogRepository(dbManager: dbManager)

        let reqId = UUID().uuidString
        let initialRecord = CommandLogRecord(
            requestId: reqId,
            peerDeviceId: UUID().uuidString,
            peerDeviceName: "iPhone 16e",
            commandType: "LOCK_MAC",
            receivedAt: "2026-11-15T11:00:00.000Z",
            status: "received"
        )
        try repo.insert(initialRecord)

        // 1. Mark started
        try repo.markExecutionStarted(requestId: reqId, startedAt: "2026-11-15T11:00:00.050Z")
        let started = try repo.fetchByRequestId(reqId)
        XCTAssertEqual(started?.status, "executing")
        XCTAssertEqual(started?.executionStartedAt, "2026-11-15T11:00:00.050Z")

        // 2. Mark completed
        try repo.updateCompletion(
            requestId: reqId,
            status: "executed",
            completedAt: "2026-11-15T11:00:00.120Z",
            resultCode: "SUCCESS",
            errorMessage: nil
        )
        let completed = try repo.fetchByRequestId(reqId)
        XCTAssertEqual(completed?.status, "executed")
        XCTAssertEqual(completed?.completedAt, "2026-11-15T11:00:00.120Z")
        XCTAssertEqual(completed?.resultCode, "SUCCESS")
        XCTAssertNil(completed?.errorMessage)
    }

    // MARK: - 6. Duplicate Request ID Constraint Rejection

    func test06_DuplicateRequestIdConstraintViolation() throws {
        let dbManager = try DatabaseManager(path: tempDatabasePath)
        defer { dbManager.close() }
        let repo = CommandLogRepository(dbManager: dbManager)

        let duplicateRequestId = "REPLAY-ATTACK-UUID-9999"
        let recordA = CommandLogRecord(
            requestId: duplicateRequestId,
            peerDeviceId: "peer-1",
            commandType: "LOCK_MAC",
            status: "executed"
        )
        try repo.insert(recordA)

        // Attempting to insert identical request_id must trigger UNIQUE constraint violation
        let recordB = CommandLogRecord(
            requestId: duplicateRequestId,
            peerDeviceId: "peer-2",
            commandType: "SLEEP_MAC",
            status: "received"
        )

        XCTAssertThrowsError(try repo.insert(recordB)) { error in
            guard let dbError = error as? DatabaseError, case .constraintViolation = dbError else {
                XCTFail("Expected DatabaseError.constraintViolation, got: \(error)")
                return
            }
        }
    }

    // MARK: - 7. SQL Injection Resilience

    func test07_SQLInjectionResilience() throws {
        let dbManager = try DatabaseManager(path: tempDatabasePath)
        defer { dbManager.close() }
        let repo = CommandLogRepository(dbManager: dbManager)

        let injectionPayloads = [
            "'; DROP TABLE command_logs; --",
            "' OR '1'='1",
            "\" OR \"1\"=\"1",
            "'; DELETE FROM command_logs WHERE '1'='1'; --",
            "Robert'); DROP TABLE Students;--"
        ]

        for (idx, payload) in injectionPayloads.enumerated() {
            let record = CommandLogRecord(
                requestId: "INJECTION-REQ-\(idx)-\(UUID().uuidString)",
                peerDeviceId: payload,
                peerDeviceName: payload,
                commandType: payload,
                status: "rejected",
                resultCode: "REJECTED",
                errorMessage: payload
            )

            XCTAssertNoThrow(try repo.insert(record))
        }

        // Verify table still exists and all malicious records were safely stored verbatim
        let recent = try repo.fetchRecent(limit: 50)
        XCTAssertEqual(recent.count, injectionPayloads.count)

        for record in recent {
            XCTAssertTrue(injectionPayloads.contains(record.peerDeviceId))
            XCTAssertTrue(injectionPayloads.contains(record.errorMessage ?? ""))
        }
    }

    // MARK: - 8. Pairing Events Repository

    func test08_PairingEventsInsertAndQuery() throws {
        let dbManager = try DatabaseManager(path: tempDatabasePath)
        defer { dbManager.close() }
        let repo = PairingEventRepository(dbManager: dbManager)

        let peerId = UUID().uuidString
        let event1 = PairingEventRecord(
            peerDeviceId: peerId,
            peerDeviceName: "iPhone 16e",
            eventType: "pairing_requested",
            occurredAt: "2026-11-15T12:00:00.000Z",
            result: "received",
            protocolVersion: "1.0"
        )
        let rowId1 = try repo.insert(event1)
        XCTAssertGreaterThan(rowId1, 0)

        let event2 = PairingEventRecord(
            peerDeviceId: peerId,
            peerDeviceName: "iPhone 16e",
            eventType: "pairing_approved",
            occurredAt: "2026-11-15T12:00:15.000Z",
            result: "success",
            protocolVersion: "1.0"
        )
        let rowId2 = try repo.insert(event2)
        XCTAssertGreaterThan(rowId2, rowId1)

        let events = try repo.fetchRecent(limit: 10)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].eventType, "pairing_approved")
        XCTAssertEqual(events[1].eventType, "pairing_requested")
    }

    // MARK: - 9. Device Sessions Repository

    func test09_DeviceSessionsInsertAndLifecycle() throws {
        let dbManager = try DatabaseManager(path: tempDatabasePath)
        defer { dbManager.close() }
        let repo = DeviceSessionRepository(dbManager: dbManager)

        let peerId = UUID().uuidString
        let session = DeviceSessionRecord(
            peerDeviceId: peerId,
            sessionStartedAt: "2026-11-15T13:00:00.000Z",
            status: "active"
        )
        let sessionId = try repo.insert(session)
        XCTAssertGreaterThan(sessionId, 0)

        // End specific session
        try repo.endSession(id: sessionId, endedAt: "2026-11-15T13:05:00.000Z", status: "closed")
        var sessions = try repo.fetchRecent(limit: 10)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].status, "closed")
        XCTAssertEqual(sessions[0].sessionEndedAt, "2026-11-15T13:05:00.000Z")

        // Insert new active session and end via endActiveSessions
        _ = try repo.insert(DeviceSessionRecord(
            peerDeviceId: peerId,
            sessionStartedAt: "2026-11-15T13:10:00.000Z",
            status: "active"
        ))
        try repo.endActiveSessions(peerDeviceId: peerId, endedAt: "2026-11-15T13:15:00.000Z", status: "terminated")

        sessions = try repo.fetchRecent(limit: 10)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].status, "terminated")
    }

    // MARK: - 10. Transaction Atomicity & Rollback

    func test10_TransactionAtomicityAndRollback() throws {
        let dbManager = try DatabaseManager(path: tempDatabasePath)
        defer { dbManager.close() }
        let repo = CommandLogRepository(dbManager: dbManager)

        enum TestIntentionalError: Error { case abort }

        // Test failed transaction: operations inside should roll back
        do {
            try dbManager.inTransaction {
                try repo.insert(CommandLogRecord(
                    requestId: "TX-ROLLBACK-1",
                    peerDeviceId: "peer-1",
                    commandType: "LOCK_MAC",
                    status: "received"
                ))

                // Throw error to trigger rollback
                throw TestIntentionalError.abort
            }
            XCTFail("Transaction should have thrown")
        } catch TestIntentionalError.abort {
            // Expected
        }

        // Verify record was rolled back
        let logsAfterAbort = try repo.fetchRecent()
        XCTAssertEqual(logsAfterAbort.count, 0, "Rolled back transaction must leave table empty")

        // Test successful transaction
        try dbManager.inTransaction {
            try repo.insert(CommandLogRecord(
                requestId: "TX-COMMIT-1",
                peerDeviceId: "peer-1",
                commandType: "LOCK_MAC",
                status: "received"
            ))
            try repo.insert(CommandLogRecord(
                requestId: "TX-COMMIT-2",
                peerDeviceId: "peer-1",
                commandType: "SLEEP_MAC",
                status: "received"
            ))
        }

        let logsAfterCommit = try repo.fetchRecent()
        XCTAssertEqual(logsAfterCommit.count, 2, "Committed transaction must persist both records")
    }

    // MARK: - 11. Concurrent Writes Under WAL Mode

    func test11_ConcurrentWritesUnderWALMode() throws {
        let dbManager = try DatabaseManager(path: tempDatabasePath)
        defer { dbManager.close() }
        let repo = CommandLogRepository(dbManager: dbManager)

        let iterations = 25
        let expectation = expectation(description: "Concurrent SQLite Writes")
        expectation.expectedFulfillmentCount = iterations

        DispatchQueue.concurrentPerform(iterations: iterations) { idx in
            do {
                let record = CommandLogRecord(
                    requestId: "CONCURRENT-REQ-\(idx)-\(UUID().uuidString)",
                    peerDeviceId: "peer-concurrent",
                    peerDeviceName: "Stress Device",
                    commandType: idx % 2 == 0 ? "LOCK_MAC" : "SLEEP_MAC",
                    receivedAt: DatabaseManager.iso8601String(),
                    status: "executed",
                    resultCode: "SUCCESS"
                )
                try repo.insert(record)
                expectation.fulfill()
            } catch {
                XCTFail("Concurrent insert \(idx) failed with: \(error)")
            }
        }

        waitForExpectations(timeout: 10.0)

        let allLogs = try repo.fetchRecent(limit: 100)
        XCTAssertEqual(allLogs.count, iterations, "All concurrent inserts must be stored safely")
    }

    // MARK: - 12. Fail-Safe Closed Database Handling

    func test12_FailSafeClosedDatabaseHandling() throws {
        let dbManager = try DatabaseManager(path: tempDatabasePath)
        let repo = CommandLogRepository(dbManager: dbManager)

        dbManager.close()

        let record = CommandLogRecord(
            requestId: "AFTER-CLOSE-REQ",
            peerDeviceId: "peer-1",
            commandType: "LOCK_MAC",
            status: "received"
        )

        XCTAssertThrowsError(try repo.insert(record)) { error in
            guard let dbError = error as? DatabaseError, case .databaseClosed = dbError else {
                XCTFail("Expected DatabaseError.databaseClosed, got: \(error)")
                return
            }
        }
    }

    // MARK: - 13. Audit Lifecycle Events Recording

    func test13_AuditLifecycleEventsRecording() throws {
        let dbManager = try DatabaseManager(path: tempDatabasePath)
        defer { dbManager.close() }
        let pairingRepo = PairingEventRepository(dbManager: dbManager)
        let sessionRepo = DeviceSessionRepository(dbManager: dbManager)

        let peerId = UUID().uuidString
        let peerName = "Test iPhone 16e"

        // 1. Pairing initiated
        try pairingRepo.insert(PairingEventRecord(
            peerDeviceId: peerId,
            peerDeviceName: peerName,
            eventType: "pairing_initiated",
            result: "advertising"
        ))

        // 2. QR invitation validated
        try pairingRepo.insert(PairingEventRecord(
            peerDeviceId: peerId,
            peerDeviceName: peerName,
            eventType: "qr_invitation_validated",
            result: "success"
        ))

        // 3. SAS confirmed
        try pairingRepo.insert(PairingEventRecord(
            peerDeviceId: peerId,
            peerDeviceName: peerName,
            eventType: "sas_confirmed",
            result: "success"
        ))

        // 4. Device connected
        let sessionId = try sessionRepo.insert(DeviceSessionRecord(
            peerDeviceId: peerId,
            sessionStartedAt: DatabaseManager.iso8601String(),
            status: "active"
        ))
        try pairingRepo.insert(PairingEventRecord(
            peerDeviceId: peerId,
            peerDeviceName: peerName,
            eventType: "device_connected",
            result: "success"
        ))

        // 5. Device disconnected
        try sessionRepo.endSession(id: sessionId, status: "closed")
        try pairingRepo.insert(PairingEventRecord(
            peerDeviceId: peerId,
            peerDeviceName: peerName,
            eventType: "device_disconnected",
            result: "closed"
        ))

        // Verify persisted events
        let events = try pairingRepo.fetchRecent(limit: 10)
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events[0].eventType, "device_disconnected")
        XCTAssertEqual(events[1].eventType, "device_connected")
        XCTAssertEqual(events[2].eventType, "sas_confirmed")
        XCTAssertEqual(events[3].eventType, "qr_invitation_validated")
        XCTAssertEqual(events[4].eventType, "pairing_initiated")

        let sessions = try sessionRepo.fetchRecent(limit: 10)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].status, "closed")
        XCTAssertNotNil(sessions[0].sessionEndedAt)
    }
}
