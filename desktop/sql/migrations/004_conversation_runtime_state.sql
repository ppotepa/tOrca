ALTER TABLE conversations RENAME TO conversations_legacy;

CREATE TABLE conversations (
    id TEXT PRIMARY KEY,
    contact_installation_id TEXT NOT NULL,
    status TEXT NOT NULL,
    last_message_preview BLOB,
    last_message_at INTEGER NOT NULL DEFAULT 0,
    unread_count INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL
);

CREATE TABLE conversation_mls (
    conversation_id TEXT PRIMARY KEY,
    snapshot BLOB NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (conversation_id)
        REFERENCES conversations(id)
        ON DELETE CASCADE
);

INSERT INTO conversations (
    id,
    contact_installation_id,
    status,
    last_message_preview,
    last_message_at,
    unread_count,
    updated_at
)
SELECT
    legacy.peer,
    legacy.peer,
    'PENDING',
    (
        SELECT message.body
        FROM messages AS message
        WHERE message.peer = legacy.peer
        ORDER BY message.created_at DESC, message.rowid DESC
        LIMIT 1
    ),
    COALESCE(
        (
            SELECT message.created_at
            FROM messages AS message
            WHERE message.peer = legacy.peer
            ORDER BY message.created_at DESC, message.rowid DESC
            LIMIT 1
        ),
        0
    ),
    CASE
        WHEN legacy.unread_count < 0 THEN 0
        ELSE legacy.unread_count
    END,
    legacy.updated_at
FROM conversations_legacy AS legacy;

INSERT INTO conversation_mls (
    conversation_id,
    snapshot,
    updated_at
)
SELECT
    peer,
    mls_state,
    updated_at
FROM conversations_legacy;

DROP TABLE conversations_legacy;

CREATE INDEX conversations_last_message
    ON conversations(last_message_at DESC, updated_at DESC);
