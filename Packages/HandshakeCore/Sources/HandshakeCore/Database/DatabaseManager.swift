import Foundation
import SQLite3
import os.log

private let logger = Logger(subsystem: "com.handshake.core", category: "Database")

public enum DatabaseError: Error, LocalizedError, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
    case constraintViolation(String)
    case migrationFailed(String)
    case databaseClosed
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open SQLite database: \(msg)"
        case .prepareFailed(let msg): return "Failed to prepare SQL statement: \(msg)"
        case .stepFailed(let msg): return "Failed to execute SQL step: \(msg)"
        case .bindFailed(let msg): return "Failed to bind SQL parameter: \(msg)"
        case .constraintViolation(let msg): return "Database constraint violation: \(msg)"
        case .migrationFailed(let msg): return "Database migration failed: \(msg)"
        case .databaseClosed: return "SQLite database handle is closed or invalid."
        case .unknown(let msg): return "Database error: \(msg)"
        }
    }
}

/// Thread-safe local SQLite database manager for Handshake audit records.
/// Handles secure directory creation (POSIX 0700/0600), connection pooling,
/// WAL mode configuration, and fail-safe operations.
public final class DatabaseManager: @unchecked Sendable {

    public static let defaultDatabasePath: String = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let handshakeDir = appSupport.appendingPathComponent("Handshake", isDirectory: true)
        return handshakeDir.appendingPathComponent("handshake.sqlite").path
    }()

    private var db: OpaquePointer?
    private let path: String
    private let lock = NSRecursiveLock()

    /// Initializes and opens the SQLite database at the specified path.
    /// Passes `":memory:"` for ephemeral in-memory databases (ideal for isolated unit tests).
    public init(path: String = DatabaseManager.defaultDatabasePath) throws {
        self.path = path
        try openDatabase()
    }

    deinit {
        close()
    }

    // MARK: - Lifecycle & Configuration

    private func openDatabase() throws {
        lock.lock()
        defer { lock.unlock() }

        // If a file-based database, secure the directory structure first
        if path != ":memory:" && !path.hasPrefix("file::memory:") {
            let fileURL = URL(fileURLWithPath: path)
            let dirURL = fileURL.deletingLastPathComponent()

            try FileManager.default.createDirectory(
                at: dirURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700] // rwx------
            )
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dirURL.path)
        }

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(path, &handle, flags, nil)

        guard status == SQLITE_OK, let openDb = handle else {
            let errorMsg = handle != nil ? String(cString: sqlite3_errmsg(handle)) : "Status code \(status)"
            if let handle = handle { sqlite3_close_v2(handle) }
            throw DatabaseError.openFailed(errorMsg)
        }

        self.db = openDb

        // Configure strict security and performance PRAGMAs
        try configurePragmas(db: openDb)

        // Run migrations
        try DatabaseMigrationManager.migrate(db: openDb)

        // If file exists, ensure permissions on the database file are restricted to user only (0600)
        if path != ":memory:" && FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    private func configurePragmas(db: OpaquePointer) throws {
        // Enforce foreign key constraints
        if sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil) != SQLITE_OK {
            logger.error("Failed to enable foreign keys: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
        }

        // Configure Write-Ahead Logging (WAL) for high concurrency and crash durability
        if path != ":memory:" {
            if sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil) != SQLITE_OK {
                logger.error("Failed to set WAL journal mode: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            if sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", nil, nil, nil) != SQLITE_OK {
                logger.error("Failed to set synchronous = NORMAL: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
        }

        // 5-second busy timeout to gracefully handle concurrent access
        sqlite3_busy_timeout(db, 5000)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let handle = db {
            sqlite3_close_v2(handle)
            self.db = nil
        }
    }

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return db != nil
    }

    // MARK: - Transaction Management

    public func inTransaction<T>(_ block: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        guard let handle = db else { throw DatabaseError.databaseClosed }

        if sqlite3_exec(handle, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) != SQLITE_OK {
            throw DatabaseError.stepFailed("Failed to begin transaction: \(String(cString: sqlite3_errmsg(handle)))")
        }

        do {
            let result = try block()
            if sqlite3_exec(handle, "COMMIT TRANSACTION;", nil, nil, nil) != SQLITE_OK {
                throw DatabaseError.stepFailed("Failed to commit transaction: \(String(cString: sqlite3_errmsg(handle)))")
            }
            return result
        } catch {
            sqlite3_exec(handle, "ROLLBACK TRANSACTION;", nil, nil, nil)
            throw error
        }
    }

    // MARK: - Execution Helpers

    public func execute(sql: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let handle = db else { throw DatabaseError.databaseClosed }
        if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
            throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    public func prepare(sql: String) throws -> OpaquePointer {
        guard let handle = db else { throw DatabaseError.databaseClosed }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let stmt = statement else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(handle)))
        }
        return stmt
    }

    public func lastInsertRowId() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = db else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    public func runWithLock<T>(_ block: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = db else { throw DatabaseError.databaseClosed }
        return try block(handle)
    }

    // MARK: - Date Formatting (UTC ISO 8601)

    public static func iso8601String(from date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    public static func date(from isoString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if let d = formatter.date(from: isoString) { return d }
        // Fallback without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: isoString)
    }
}
