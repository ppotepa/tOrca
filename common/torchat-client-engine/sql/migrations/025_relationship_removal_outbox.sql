-- Durable typed relationship-removal intent.  The local tombstone and this
-- outbox row are written in the same SQLite transaction by the runtime.
ALTER TABLE relationship_tombstones ADD COLUMN relationship_epoch INTEGER NOT NULL DEFAULT 0;
ALTER TABLE relationship_tombstones ADD COLUMN removal_id TEXT;

CREATE TABLE IF NOT EXISTS relationship_removal_outbox (
    removal_id TEXT PRIMARY KEY,
    contact_installation_id TEXT NOT NULL,
    relationship_epoch INTEGER NOT NULL,
    preserve_history INTEGER NOT NULL DEFAULT 1,
    state TEXT NOT NULL DEFAULT 'PENDING',
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE INDEX IF NOT EXISTS idx_relationship_removal_outbox_retry
ON relationship_removal_outbox(state, next_attempt_at, removal_id);
