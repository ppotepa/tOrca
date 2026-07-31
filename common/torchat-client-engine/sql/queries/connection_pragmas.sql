PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;

-- These base declarations are byte-compatible with migration 001. Connection
-- pragmas run before MigrationRunner, so the durable recovery and relationship
-- triggers need their target tables to exist on both fresh and existing stores.
CREATE TABLE IF NOT EXISTS contacts (
    installation_id TEXT PRIMARY KEY,
    nickname TEXT NOT NULL,
    public_key TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    key_package BLOB,
    verification TEXT NOT NULL,
    source TEXT NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    contact_installation_id TEXT NOT NULL UNIQUE,
    state TEXT NOT NULL,
    unread_count INTEGER NOT NULL DEFAULT 0,
    last_message_preview TEXT,
    last_message_at INTEGER,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (contact_installation_id)
        REFERENCES contacts(installation_id)
);

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

-- This table is declared here as well as in the canonical migration because
-- the recovery trigger must exist before any actor can acknowledge a forwarded
-- Welcome.
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

-- State timestamps are kept in the same encrypted SQLCipher database without
-- expanding the canonical ChatMessage wire contract.
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
        message_id, sent_at, delivered_at, read_at
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
        message_id, sent_at, delivered_at, read_at
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

-- A relationship boundary identifies the most recent accepted relationship
-- with a contact. Delayed removal messages from an older relationship are
-- ignored even if they are replayed after a successful fresh pairing.
CREATE TABLE IF NOT EXISTS relationship_boundaries (
    contact_installation_id TEXT PRIMARY KEY,
    boundary_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS relationship_tombstones (
    contact_installation_id TEXT PRIMARY KEY,
    removed_at INTEGER NOT NULL,
    preserve_history INTEGER NOT NULL DEFAULT 1
);

INSERT INTO relationship_boundaries (contact_installation_id, boundary_at)
SELECT installation_id, updated_at * 1000 FROM contacts
ON CONFLICT(contact_installation_id) DO NOTHING;

CREATE TRIGGER IF NOT EXISTS record_inserted_relationship_boundary
AFTER INSERT ON contacts
BEGIN
    INSERT INTO relationship_boundaries (contact_installation_id, boundary_at)
    VALUES (
        NEW.installation_id,
        CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)
    )
    ON CONFLICT(contact_installation_id) DO UPDATE SET
        boundary_at = MAX(relationship_boundaries.boundary_at, excluded.boundary_at);
END;

CREATE TRIGGER IF NOT EXISTS record_reactivated_relationship_boundary
AFTER UPDATE ON contacts
WHEN (COALESCE(OLD.blocked, 0) <> 0 AND COALESCE(NEW.blocked, 0) = 0)
  OR (UPPER(OLD.verification) <> 'VERIFIED' AND UPPER(NEW.verification) = 'VERIFIED')
BEGIN
    INSERT INTO relationship_boundaries (contact_installation_id, boundary_at)
    VALUES (
        NEW.installation_id,
        CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)
    )
    ON CONFLICT(contact_installation_id) DO UPDATE SET
        boundary_at = MAX(relationship_boundaries.boundary_at, excluded.boundary_at);
END;

-- Consume stale relationship-removal messages without allowing them to mutate
-- a newly paired relationship. The engine still acknowledges the encrypted
-- envelope, so the old sender does not retry forever.
CREATE TRIGGER IF NOT EXISTS ignore_stale_relationship_removal
BEFORE INSERT ON messages
WHEN NEW.outgoing = 0
 AND substr(NEW.body, 1, length('torchat-relationship-removed-v1:'))
        = 'torchat-relationship-removed-v1:'
 AND json_valid(substr(
        NEW.body,
        length('torchat-relationship-removed-v1:') + 1
     ))
 AND CAST((
        julianday(json_extract(
            substr(NEW.body, length('torchat-relationship-removed-v1:') + 1),
            '$.removedAt'
        )) - 2440587.5
     ) * 86400000 AS INTEGER) < COALESCE((
        SELECT boundary_at
        FROM relationship_boundaries
        WHERE contact_installation_id = (
            SELECT contact_installation_id
            FROM conversations
            WHERE id = NEW.conversation_id
        )
     ), 0)
BEGIN
    SELECT RAISE(IGNORE);
END;

-- A valid incoming removal message atomically creates the tombstone, disables
-- the contact, stops ordinary queued traffic and removes technical MLS/endpoint
-- state. The removal message itself remains as a local system event.
CREATE TRIGGER IF NOT EXISTS apply_incoming_relationship_removal
AFTER INSERT ON messages
WHEN NEW.outgoing = 0
 AND substr(NEW.body, 1, length('torchat-relationship-removed-v1:'))
        = 'torchat-relationship-removed-v1:'
 AND json_valid(substr(
        NEW.body,
        length('torchat-relationship-removed-v1:') + 1
     ))
 AND CAST((
        julianday(json_extract(
            substr(NEW.body, length('torchat-relationship-removed-v1:') + 1),
            '$.removedAt'
        )) - 2440587.5
     ) * 86400000 AS INTEGER) >= COALESCE((
        SELECT boundary_at
        FROM relationship_boundaries
        WHERE contact_installation_id = (
            SELECT contact_installation_id
            FROM conversations
            WHERE id = NEW.conversation_id
        )
     ), 0)
BEGIN
    INSERT INTO relationship_tombstones (
        contact_installation_id, removed_at, preserve_history
    ) VALUES (
        (SELECT contact_installation_id
         FROM conversations WHERE id = NEW.conversation_id),
        CAST((
            julianday(json_extract(
                substr(NEW.body, length('torchat-relationship-removed-v1:') + 1),
                '$.removedAt'
            )) - 2440587.5
        ) * 86400000 AS INTEGER),
        CASE WHEN json_extract(
            substr(NEW.body, length('torchat-relationship-removed-v1:') + 1),
            '$.preserveHistory'
        ) = 0 THEN 0 ELSE 1 END
    )
    ON CONFLICT(contact_installation_id) DO UPDATE SET
        removed_at = MAX(relationship_tombstones.removed_at, excluded.removed_at),
        preserve_history = excluded.preserve_history;

    UPDATE contacts
    SET blocked = 1, updated_at = unixepoch()
    WHERE installation_id = (
        SELECT contact_installation_id
        FROM conversations WHERE id = NEW.conversation_id
    );

    UPDATE conversations
    SET state = 'OFFLINE', updated_at = unixepoch()
    WHERE id = NEW.conversation_id;

    UPDATE messages
    SET state = 'FAILED',
        next_attempt_at = 0,
        ack_deadline = NULL,
        last_transport_error = 'relationship removed'
    WHERE conversation_id = NEW.conversation_id
      AND outgoing = 1
      AND UPPER(state) IN ('QUEUED', 'SENDING')
      AND substr(body, 1, length('torchat-relationship-removed-v1:'))
            <> 'torchat-relationship-removed-v1:';

    DELETE FROM outbound_deliveries
    WHERE contact_installation_id = (
        SELECT contact_installation_id
        FROM conversations WHERE id = NEW.conversation_id
    )
      AND message_id NOT IN (
        SELECT id FROM messages
        WHERE substr(body, 1, length('torchat-relationship-removed-v1:'))
                = 'torchat-relationship-removed-v1:'
      );

    DELETE FROM delivery_receipts
    WHERE conversation_id = NEW.conversation_id;

    DELETE FROM messages
    WHERE conversation_id = NEW.conversation_id
      AND id <> NEW.id
      AND substr(body, 1, length('torchat-relationship-removed-v1:'))
            <> 'torchat-relationship-removed-v1:'
      AND json_extract(
            substr(NEW.body, length('torchat-relationship-removed-v1:') + 1),
            '$.preserveHistory'
          ) = 0;

    DELETE FROM conversation_mls
    WHERE conversation_id = NEW.conversation_id;
    DELETE FROM contact_peer_endpoints
    WHERE contact_installation_id = (
        SELECT contact_installation_id
        FROM conversations WHERE id = NEW.conversation_id
    );
    DELETE FROM endpoint_update_outbox
    WHERE contact_installation_id = (
        SELECT contact_installation_id
        FROM conversations WHERE id = NEW.conversation_id
    );
    DELETE FROM peer_endpoint_bootstrap_outbox
    WHERE contact_installation_id = (
        SELECT contact_installation_id
        FROM conversations WHERE id = NEW.conversation_id
    );
    DELETE FROM pending_contact_confirmations
    WHERE peer_installation_id = (
        SELECT contact_installation_id
        FROM conversations WHERE id = NEW.conversation_id
    );
    DELETE FROM pending_peer_endpoint_inbox
    WHERE contact_installation_id = (
        SELECT contact_installation_id
        FROM conversations WHERE id = NEW.conversation_id
    );
END;

-- The actor persists the post-decryption MLS snapshot after the message row. A
-- tombstoned relationship must not be able to recreate that technical state.
CREATE TRIGGER IF NOT EXISTS suppress_removed_relationship_mls_insert
BEFORE INSERT ON conversation_mls
WHEN EXISTS (
    SELECT 1
    FROM conversations
    JOIN relationship_tombstones
      ON relationship_tombstones.contact_installation_id
         = conversations.contact_installation_id
    WHERE conversations.id = NEW.conversation_id
)
BEGIN
    SELECT RAISE(IGNORE);
END;

CREATE TRIGGER IF NOT EXISTS suppress_removed_relationship_mls_update
BEFORE UPDATE ON conversation_mls
WHEN EXISTS (
    SELECT 1
    FROM conversations
    JOIN relationship_tombstones
      ON relationship_tombstones.contact_installation_id
         = conversations.contact_installation_id
    WHERE conversations.id = NEW.conversation_id
)
BEGIN
    SELECT RAISE(IGNORE);
END;

CREATE TRIGGER IF NOT EXISTS suppress_removed_contact_endpoint_insert
BEFORE INSERT ON contact_peer_endpoints
WHEN EXISTS (
    SELECT 1 FROM relationship_tombstones
    WHERE contact_installation_id = NEW.contact_installation_id
)
BEGIN
    SELECT RAISE(IGNORE);
END;

CREATE TRIGGER IF NOT EXISTS suppress_removed_contact_endpoint_update
BEFORE UPDATE ON contact_peer_endpoints
WHEN EXISTS (
    SELECT 1 FROM relationship_tombstones
    WHERE contact_installation_id = NEW.contact_installation_id
)
BEGIN
    SELECT RAISE(IGNORE);
END;
