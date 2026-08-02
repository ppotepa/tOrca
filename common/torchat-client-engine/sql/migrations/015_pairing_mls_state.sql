CREATE TABLE IF NOT EXISTS pending_local_invite_mls (
    invite_id TEXT PRIMARY KEY,
    recipient_installation_id TEXT,
    snapshot BLOB NOT NULL,
    expires_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE INDEX IF NOT EXISTS idx_pending_local_invite_mls_expiry
ON pending_local_invite_mls(expires_at, invite_id);

DROP TRIGGER IF EXISTS retain_forwarded_pending_welcome;

DELETE FROM settings WHERE key = 'mls_inbox_snapshot_v1';
