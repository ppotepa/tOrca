ALTER TABLE messages
ADD COLUMN wire_ciphertext BLOB;

UPDATE messages
SET wire_ciphertext = relay_payload
WHERE wire_ciphertext IS NULL
  AND relay_payload IS NOT NULL;

CREATE TABLE IF NOT EXISTS local_peer_endpoint (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    bundle_json BLOB NOT NULL,
    sequence INTEGER NOT NULL,
    generation INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS contact_peer_endpoints (
    contact_installation_id TEXT PRIMARY KEY,
    bundle_json BLOB NOT NULL,
    sequence INTEGER NOT NULL,
    last_connected_at INTEGER,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (contact_installation_id)
        REFERENCES contacts(installation_id)
        ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS outbound_deliveries (
    message_id TEXT PRIMARY KEY,
    contact_installation_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    state TEXT NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    ack_deadline INTEGER,
    last_error TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (message_id)
        REFERENCES messages(id)
        ON DELETE CASCADE,
    FOREIGN KEY (contact_installation_id)
        REFERENCES contacts(installation_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_outbound_deliveries_retry
ON outbound_deliveries(state, next_attempt_at, created_at, message_id);

CREATE TABLE IF NOT EXISTS inbound_peer_envelopes (
    sender_installation_id TEXT NOT NULL,
    message_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    ciphertext BLOB NOT NULL,
    ciphertext_hash BLOB NOT NULL,
    state TEXT NOT NULL,
    received_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (sender_installation_id, message_id)
);

CREATE INDEX IF NOT EXISTS idx_inbound_peer_envelopes_pending
ON inbound_peer_envelopes(state, received_at, message_id);

CREATE TABLE IF NOT EXISTS endpoint_update_outbox (
    contact_installation_id TEXT NOT NULL,
    payload BLOB NOT NULL,
    sequence INTEGER NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (contact_installation_id, sequence),
    FOREIGN KEY (contact_installation_id)
        REFERENCES contacts(installation_id)
        ON DELETE CASCADE
);
