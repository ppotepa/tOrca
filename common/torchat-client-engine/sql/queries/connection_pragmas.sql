PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;

-- This table is declared here as well as in the canonical migration because
-- connection pragmas run before MigrationRunner on both new and existing
-- databases. Keeping the declaration byte-compatible lets the recovery trigger
-- be installed before any actor can acknowledge a forwarded Welcome.
CREATE TABLE IF NOT EXISTS pending_welcomes (
    invite_id TEXT PRIMARY KEY,
    recipient_installation_id TEXT NOT NULL,
    payload BLOB NOT NULL,
    expires_at INTEGER NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    last_error TEXT
);

-- Relay FORWARDED only proves that the relay accepted the envelope. It does not
-- prove that the recipient applied the MLS Welcome and committed the contact.
-- The legacy actor calls DELETE after FORWARDED; convert that early delete into
-- a retained retry. The first forward is retried after at least five seconds;
-- later attempts keep the scheduler's exponential deadline. The row remains
-- available for duplicate-offer recovery and is deleted normally after expiry.
CREATE TRIGGER IF NOT EXISTS retain_forwarded_pending_welcome
BEFORE DELETE ON pending_welcomes
WHEN OLD.expires_at > unixepoch()
BEGIN
    UPDATE pending_welcomes
    SET next_attempt_at = CASE
            WHEN OLD.next_attempt_at > unixepoch() * 1000
                THEN OLD.next_attempt_at
            ELSE (unixepoch() + 5) * 1000
        END,
        last_error = NULL
    WHERE invite_id = OLD.invite_id;
    SELECT RAISE(IGNORE);
END;

-- The base messages declaration matches migration 001. Connection pragmas run
-- before the migration runner, so a fresh database needs this table in place
-- before the timestamp triggers can be installed. Later migrations still add
-- their own nullable columns normally.
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    outgoing INTEGER NOT NULL,
    body TEXT NOT NULL,
    state TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    relay_payload BLOB,
    ciphertext_hash BLOB,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    last_attempt_at INTEGER,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    ack_deadline INTEGER,
    last_transport_error TEXT,
    FOREIGN KEY (conversation_id)
        REFERENCES conversations(id)
        ON DELETE CASCADE
);

-- State timestamps are kept in the same encrypted SQLCipher database without
-- expanding the canonical ChatMessage wire contract. The table survives UI and
-- process restarts and can be joined by future projections without rewriting
-- existing message rows.
CREATE TABLE IF NOT EXISTS message_state_timestamps (
    message_id TEXT PRIMARY KEY,
    sent_at INTEGER,
    delivered_at INTEGER,
    read_at INTEGER,
    FOREIGN KEY (message_id)
        REFERENCES messages(id)
        ON DELETE CASCADE
);

CREATE TRIGGER IF NOT EXISTS record_inserted_message_state_timestamps
AFTER INSERT ON messages
WHEN UPPER(NEW.state) IN ('SENT', 'DELIVERED', 'READ')
BEGIN
    INSERT INTO message_state_timestamps (
        message_id,
        sent_at,
        delivered_at,
        read_at
    ) VALUES (
        NEW.id,
        CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER),
        CASE WHEN UPPER(NEW.state) IN ('DELIVERED', 'READ')
            THEN CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)
            ELSE NULL END,
        CASE WHEN UPPER(NEW.state) = 'READ'
            THEN CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)
            ELSE NULL END
    )
    ON CONFLICT(message_id) DO UPDATE SET
        sent_at = COALESCE(message_state_timestamps.sent_at, excluded.sent_at),
        delivered_at = COALESCE(message_state_timestamps.delivered_at, excluded.delivered_at),
        read_at = COALESCE(message_state_timestamps.read_at, excluded.read_at);
END;

CREATE TRIGGER IF NOT EXISTS record_updated_message_state_timestamps
AFTER UPDATE OF state ON messages
WHEN UPPER(NEW.state) IN ('SENT', 'DELIVERED', 'READ')
BEGIN
    INSERT INTO message_state_timestamps (
        message_id,
        sent_at,
        delivered_at,
        read_at
    ) VALUES (
        NEW.id,
        CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER),
        CASE WHEN UPPER(NEW.state) IN ('DELIVERED', 'READ')
            THEN CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)
            ELSE NULL END,
        CASE WHEN UPPER(NEW.state) = 'READ'
            THEN CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)
            ELSE NULL END
    )
    ON CONFLICT(message_id) DO UPDATE SET
        sent_at = COALESCE(message_state_timestamps.sent_at, excluded.sent_at),
        delivered_at = COALESCE(message_state_timestamps.delivered_at, excluded.delivered_at),
        read_at = COALESCE(message_state_timestamps.read_at, excluded.read_at);
END;

CREATE VIEW IF NOT EXISTS messages_with_state_timestamps AS
SELECT
    messages.*,
    message_state_timestamps.sent_at,
    message_state_timestamps.delivered_at,
    message_state_timestamps.read_at
FROM messages
LEFT JOIN message_state_timestamps
    ON message_state_timestamps.message_id = messages.id;
