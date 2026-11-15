-- ==============================================================================
-- HANDSHAKE V1 — LOCAL SQLITE AUDIT DATABASE SCHEMA
-- Path: ~/Library/Application Support/Handshake/handshake.sqlite
-- 
-- Zero-Cloud Architecture:
-- Stored locally on the host Mac with user-only permissions (0700/0600).
-- NEVER stores private keys, pre-shared keys, ephemeral secrets, or plaintext payloads.
-- ==============================================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA busy_timeout = 5000;

-- ------------------------------------------------------------------------------
-- 1. COMMAND AUDIT LOGS
-- Tracks every authenticated or rejected command submitted to this Mac.
-- ------------------------------------------------------------------------------
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

-- ------------------------------------------------------------------------------
-- 2. PAIRING LIFECYCLE EVENTS
-- Audits all device pairing invitations, requests, and bilateral approvals.
-- ------------------------------------------------------------------------------
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

-- ------------------------------------------------------------------------------
-- 3. DEVICE SESSION TRACKING
-- Tracks authenticated peer-to-peer transport sessions over local Wi-Fi or BLE.
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS device_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    peer_device_id TEXT NOT NULL,
    session_started_at TEXT NOT NULL,
    session_ended_at TEXT,
    status TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_device_sessions_peer
ON device_sessions(peer_device_id);

-- User schema version tracking
PRAGMA user_version = 1;
