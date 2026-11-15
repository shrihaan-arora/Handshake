import Foundation
import SQLite3

/// Handles automatic schema migrations for the local SQLite database
/// utilizing `PRAGMA user_version`.
public enum DatabaseMigrationManager {

    public static let targetSchemaVersion: Int32 = 1

    public static func currentVersion(db: OpaquePointer) -> Int32 {
        var version: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                version = sqlite3_column_int(stmt, 0)
            }
            sqlite3_finalize(stmt)
        }
        return version
    }

    public static func migrate(db: OpaquePointer) throws {
        let version = currentVersion(db: db)

        if version < 1 {
            try applyMigrationV1(db: db)
        }
    }

    private static func applyMigrationV1(db: OpaquePointer) throws {
        let v1SchemaSQL = """
        CREATE TABLE IF NOT EXISTS command_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            request_id TEXT NOT NULL UNIQUE,
            peer_device_id TEXT NOT NULL,
            peer_device_name TEXT,
            command_type TEXT NOT NULL,
            received_at TEXT NOT NULL,
            execution_started_at TEXT,
            completed_at TEXT,
            status TEXT NOT NULL,
            result_code TEXT,
            error_message TEXT,
            protocol_version TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_command_logs_received_at
        ON command_logs(received_at);

        CREATE INDEX IF NOT EXISTS idx_command_logs_peer
        ON command_logs(peer_device_id);

        CREATE TABLE IF NOT EXISTS pairing_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            peer_device_id TEXT NOT NULL,
            peer_device_name TEXT,
            event_type TEXT NOT NULL,
            occurred_at TEXT NOT NULL,
            result TEXT NOT NULL,
            protocol_version TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_pairing_events_occurred_at
        ON pairing_events(occurred_at);

        CREATE TABLE IF NOT EXISTS device_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            peer_device_id TEXT NOT NULL,
            session_started_at TEXT NOT NULL,
            session_ended_at TEXT,
            status TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_device_sessions_peer
        ON device_sessions(peer_device_id);

        PRAGMA user_version = 1;
        """

        if sqlite3_exec(db, v1SchemaSQL, nil, nil, nil) != SQLITE_OK {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.migrationFailed("Migration to version 1 failed: \(errorMsg)")
        }
    }
}
