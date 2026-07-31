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
-- a dormant retained record. A duplicate pairing offer can then resend the
-- exact same Welcome, while the normal retry scheduler sleeps until expiry.
CREATE TRIGGER IF NOT EXISTS retain_forwarded_pending_welcome
BEFORE DELETE ON pending_welcomes
WHEN OLD.expires_at > unixepoch()
BEGIN
    UPDATE pending_welcomes
    SET next_attempt_at = OLD.expires_at * 1000,
        last_error = NULL
    WHERE invite_id = OLD.invite_id;
    SELECT RAISE(IGNORE);
END;
