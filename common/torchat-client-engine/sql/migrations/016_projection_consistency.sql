CREATE TABLE IF NOT EXISTS projection_meta (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    store_id TEXT NOT NULL,
    global_revision INTEGER NOT NULL DEFAULT 0
);

INSERT OR IGNORE INTO projection_meta (singleton, store_id, global_revision)
VALUES (1, lower(hex(randomblob(16))), 0);

CREATE TABLE IF NOT EXISTS conversation_projection_revisions (
    conversation_id TEXT PRIMARY KEY,
    revision INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS processed_commands (
    command_id TEXT PRIMARY KEY,
    command_type TEXT NOT NULL,
    result_json BLOB NOT NULL,
    committed_revision INTEGER NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE INDEX IF NOT EXISTS idx_processed_commands_created_at
ON processed_commands(created_at);
