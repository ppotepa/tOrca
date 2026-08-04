-- TorChat V1 base schema.
-- This is the complete schema for the unreleased local-first client. It
-- intentionally contains no relay mailbox or server-control-plane tables.

CREATE TABLE settings (key TEXT PRIMARY KEY, value BLOB NOT NULL);
CREATE TABLE contacts (
    installation_id TEXT PRIMARY KEY, nickname TEXT NOT NULL,
    public_key TEXT NOT NULL, fingerprint TEXT NOT NULL,
    key_package BLOB, verification TEXT NOT NULL, source TEXT NOT NULL,
    local_alias TEXT, muted INTEGER NOT NULL DEFAULT 0,
    blocked INTEGER NOT NULL DEFAULT 0,
    transport_policy TEXT NOT NULL DEFAULT 'PEER_ONLY',
    last_seen_at INTEGER, created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE TABLE conversations (
    id TEXT PRIMARY KEY, contact_installation_id TEXT NOT NULL UNIQUE,
    state TEXT NOT NULL, unread_count INTEGER NOT NULL DEFAULT 0,
    last_message_preview TEXT, last_message_at INTEGER,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (contact_installation_id) REFERENCES contacts(installation_id)
);
CREATE TABLE conversation_mls (
    conversation_id TEXT PRIMARY KEY, snapshot BLOB NOT NULL,
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    state_version INTEGER NOT NULL DEFAULT 0, snapshot_hash BLOB,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);
CREATE TABLE messages (
    id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, outgoing INTEGER NOT NULL,
    body TEXT NOT NULL, state TEXT NOT NULL, created_at INTEGER NOT NULL,
    ciphertext_hash BLOB, attempt_count INTEGER NOT NULL DEFAULT 0,
    last_attempt_at INTEGER, next_attempt_at INTEGER NOT NULL DEFAULT 0,
    ack_deadline INTEGER, last_transport_error TEXT, reply_to_json TEXT,
    wire_ciphertext BLOB, claimed_until INTEGER, last_error_code TEXT,
    dead_lettered_at INTEGER,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);
CREATE TABLE pairing_inbox (
    pairing_id TEXT PRIMARY KEY, sender_installation_id TEXT NOT NULL,
    sender_nickname TEXT NOT NULL, sender_public_key TEXT NOT NULL,
    sender_fingerprint TEXT NOT NULL, capability TEXT NOT NULL,
    expires_at INTEGER NOT NULL, state TEXT NOT NULL, offer_invite_id TEXT,
    offer_payload BLOB, attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0, last_error TEXT,
    response_delivered INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE TABLE pairing_outbox (
    pairing_id TEXT PRIMARY KEY, recipient_installation_id TEXT,
    capability TEXT, payload BLOB, expires_at INTEGER NOT NULL,
    state TEXT NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0, last_error TEXT,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE TABLE pending_welcomes (
    invite_id TEXT PRIMARY KEY, recipient_installation_id TEXT NOT NULL,
    payload BLOB NOT NULL, expires_at INTEGER NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0, last_error TEXT,
    dead_lettered_at INTEGER
);
CREATE TABLE used_invites (invite_id TEXT PRIMARY KEY, used_at INTEGER NOT NULL);
CREATE TABLE received_envelopes (
    sender_installation_id TEXT NOT NULL, message_id TEXT NOT NULL,
    ciphertext_hash BLOB NOT NULL, received_at INTEGER NOT NULL,
    receipt_state TEXT NOT NULL,
    PRIMARY KEY (sender_installation_id, message_id)
);
CREATE TABLE delivery_receipts (
    envelope_id TEXT PRIMARY KEY, message_id TEXT NOT NULL UNIQUE,
    conversation_id TEXT NOT NULL, original_sender TEXT NOT NULL,
    received_at INTEGER NOT NULL, state TEXT NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0, last_error TEXT,
    created_at INTEGER NOT NULL, claimed_until INTEGER,
    last_error_code TEXT, dead_lettered_at INTEGER, wire_ciphertext BLOB
);
CREATE TABLE local_peer_endpoint (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    bundle_json BLOB NOT NULL, sequence INTEGER NOT NULL,
    generation INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE TABLE contact_peer_endpoints (
    contact_installation_id TEXT PRIMARY KEY, bundle_json BLOB NOT NULL,
    sequence INTEGER NOT NULL, last_connected_at INTEGER,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (contact_installation_id) REFERENCES contacts(installation_id)
        ON DELETE CASCADE
);
CREATE TABLE outbound_deliveries (
    message_id TEXT PRIMARY KEY, contact_installation_id TEXT NOT NULL,
    sequence INTEGER NOT NULL, state TEXT NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0, ack_deadline INTEGER,
    last_error TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
    claimed_until INTEGER, last_error_code TEXT, dead_lettered_at INTEGER,
    FOREIGN KEY (message_id) REFERENCES messages(id) ON DELETE CASCADE,
    FOREIGN KEY (contact_installation_id) REFERENCES contacts(installation_id)
        ON DELETE CASCADE
);
CREATE TABLE inbound_peer_envelopes (
    sender_installation_id TEXT NOT NULL, message_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL, sequence INTEGER NOT NULL,
    ciphertext BLOB NOT NULL, ciphertext_hash BLOB NOT NULL,
    state TEXT NOT NULL, received_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
    PRIMARY KEY (sender_installation_id, message_id)
);
CREATE TABLE endpoint_update_outbox (
    contact_installation_id TEXT NOT NULL, payload BLOB NOT NULL,
    sequence INTEGER NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0, last_error TEXT,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (contact_installation_id, sequence),
    FOREIGN KEY (contact_installation_id) REFERENCES contacts(installation_id)
        ON DELETE CASCADE
);
CREATE TABLE pending_peer_endpoint_inbox (
    contact_installation_id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL,
    endpoint_sequence INTEGER NOT NULL, received_at INTEGER NOT NULL
);
CREATE TABLE message_state_timestamps (
    message_id TEXT PRIMARY KEY, sent_at INTEGER, delivered_at INTEGER,
    read_at INTEGER, FOREIGN KEY (message_id) REFERENCES messages(id)
        ON DELETE CASCADE
);
CREATE TABLE relationship_boundaries (
    contact_installation_id TEXT PRIMARY KEY, boundary_at INTEGER NOT NULL,
    relationship_epoch INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE relationship_tombstones (
    contact_installation_id TEXT PRIMARY KEY, removed_at INTEGER NOT NULL,
    preserve_history INTEGER NOT NULL DEFAULT 1,
    relationship_epoch INTEGER NOT NULL DEFAULT 0, removal_id TEXT
);
CREATE TABLE pending_local_invite_mls (
    invite_id TEXT PRIMARY KEY, recipient_installation_id TEXT,
    snapshot BLOB NOT NULL, expires_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE TABLE projection_meta (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1), store_id TEXT NOT NULL,
    global_revision INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE conversation_projection_revisions (
    conversation_id TEXT PRIMARY KEY, revision INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);
CREATE TABLE processed_commands (
    command_id TEXT PRIMARY KEY, command_type TEXT NOT NULL,
    result_json BLOB NOT NULL, committed_revision INTEGER NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE TABLE contact_endpoint_capabilities (
    contact_installation_id TEXT PRIMARY KEY, capability_id TEXT NOT NULL UNIQUE,
    secret_hash BLOB NOT NULL, secret_ciphertext BLOB NOT NULL,
    sequence INTEGER NOT NULL DEFAULT 1, issued_at INTEGER NOT NULL,
    expires_at INTEGER, revoked_at INTEGER, updated_at INTEGER NOT NULL,
    FOREIGN KEY (contact_installation_id) REFERENCES contacts(installation_id)
        ON DELETE CASCADE
);
CREATE TABLE peer_endpoint_capabilities (
    contact_installation_id TEXT PRIMARY KEY, capability_id TEXT NOT NULL,
    secret_hash BLOB NOT NULL, secret_ciphertext BLOB NOT NULL,
    sequence INTEGER NOT NULL DEFAULT 1, issued_at INTEGER NOT NULL,
    expires_at INTEGER, revoked_at INTEGER, updated_at INTEGER NOT NULL,
    FOREIGN KEY (contact_installation_id) REFERENCES contacts(installation_id)
        ON DELETE CASCADE
);
CREATE UNIQUE INDEX idx_peer_endpoint_capabilities_id
    ON peer_endpoint_capabilities(capability_id);
CREATE TABLE pending_application_envelopes (
    sender_installation_id TEXT NOT NULL, message_id TEXT NOT NULL,
    envelope_json TEXT NOT NULL, ciphertext BLOB NOT NULL,
    ciphertext_hash BLOB NOT NULL, received_at INTEGER NOT NULL,
    PRIMARY KEY (sender_installation_id, message_id)
);
CREATE TABLE capability_delivery_outbox (
    delivery_id TEXT PRIMARY KEY NOT NULL, contact_installation_id TEXT NOT NULL,
    payload BLOB NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0, last_error TEXT,
    created_at INTEGER NOT NULL, dead_lettered_at INTEGER
);
CREATE TABLE delivery_dead_letters (
    kind TEXT NOT NULL, item_id TEXT NOT NULL, contact_installation_id TEXT,
    attempt_count INTEGER NOT NULL, last_error TEXT NOT NULL,
    created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
    PRIMARY KEY (kind, item_id)
);
CREATE TABLE read_receipt_outbox (
    receipt_id TEXT PRIMARY KEY, contact_installation_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL, message_ids_json TEXT NOT NULL,
    read_at INTEGER NOT NULL, wire_ciphertext BLOB,
    state TEXT NOT NULL DEFAULT 'QUEUED', attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0, last_error TEXT,
    created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
    UNIQUE(contact_installation_id, conversation_id, message_ids_json),
    FOREIGN KEY (contact_installation_id) REFERENCES contacts(installation_id)
        ON DELETE CASCADE
);
CREATE TABLE relationship_removal_outbox (
    removal_id TEXT PRIMARY KEY, contact_installation_id TEXT NOT NULL,
    relationship_epoch INTEGER NOT NULL, preserve_history INTEGER NOT NULL DEFAULT 1,
    state TEXT NOT NULL DEFAULT 'PENDING', attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0, last_error TEXT,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE TABLE relationship_removal_ack_outbox (
    removal_id TEXT PRIMARY KEY, contact_installation_id TEXT NOT NULL,
    relationship_epoch INTEGER NOT NULL, payload BLOB NOT NULL,
    state TEXT NOT NULL DEFAULT 'PENDING', attempt_count INTEGER NOT NULL DEFAULT 0,
    claimed_until INTEGER, next_attempt_at INTEGER NOT NULL DEFAULT 0,
    last_error TEXT, last_error_code TEXT, dead_lettered_at INTEGER,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX idx_conversations_last_message ON conversations(last_message_at DESC, id ASC);
CREATE INDEX idx_messages_conversation_created ON messages(conversation_id, created_at ASC, id ASC);
CREATE INDEX idx_messages_retry ON messages(outgoing, state, next_attempt_at, created_at, id);
CREATE INDEX idx_messages_ack_deadline ON messages(outgoing, state, ack_deadline, created_at, id);
CREATE INDEX idx_delivery_receipts_retry ON delivery_receipts(state, next_attempt_at, created_at, envelope_id);
CREATE INDEX idx_pending_welcomes_retry ON pending_welcomes(expires_at, next_attempt_at, invite_id);
CREATE INDEX idx_pairing_inbox_response_retry ON pairing_inbox(response_delivered, state, expires_at, next_attempt_at, pairing_id);
CREATE INDEX idx_pairing_outbox_retry ON pairing_outbox(state, expires_at, next_attempt_at, pairing_id);
CREATE INDEX idx_outbound_deliveries_retry ON outbound_deliveries(state, next_attempt_at, created_at, message_id);
CREATE INDEX idx_inbound_peer_envelopes_pending ON inbound_peer_envelopes(state, received_at, message_id);
CREATE INDEX idx_pending_peer_endpoint_inbox_received ON pending_peer_endpoint_inbox(received_at);
CREATE INDEX idx_pending_local_invite_mls_expiry ON pending_local_invite_mls(expires_at, invite_id);
CREATE INDEX idx_processed_commands_created_at ON processed_commands(created_at);
CREATE INDEX idx_contact_endpoint_capabilities_active ON contact_endpoint_capabilities(revoked_at, expires_at, contact_installation_id);
CREATE INDEX idx_pending_application_envelopes_received ON pending_application_envelopes(received_at);
CREATE INDEX idx_capability_delivery_outbox_due ON capability_delivery_outbox(next_attempt_at, created_at);
CREATE INDEX idx_capability_delivery_dead_letters ON capability_delivery_outbox(dead_lettered_at, next_attempt_at);
CREATE INDEX idx_read_receipt_outbox_retry ON read_receipt_outbox(state, next_attempt_at, created_at, receipt_id);
CREATE INDEX idx_relationship_removal_outbox_retry ON relationship_removal_outbox(state, next_attempt_at, removal_id);
CREATE INDEX idx_relationship_removal_ack_retry ON relationship_removal_ack_outbox(state, next_attempt_at, removal_id);
CREATE INDEX idx_message_state_timestamps_message ON message_state_timestamps(message_id);
CREATE TRIGGER record_inserted_message_state_timestamps
AFTER INSERT ON messages
WHEN UPPER(NEW.state) IN ('SENT', 'DELIVERED', 'READ')
BEGIN
    INSERT INTO message_state_timestamps(message_id, sent_at, delivered_at, read_at)
    VALUES (NEW.id,
        CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER),
        CASE WHEN UPPER(NEW.state) IN ('DELIVERED', 'READ') THEN CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER) END,
        CASE WHEN UPPER(NEW.state) = 'READ' THEN CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER) END)
    ON CONFLICT(message_id) DO UPDATE SET
        sent_at = COALESCE(message_state_timestamps.sent_at, excluded.sent_at),
        delivered_at = COALESCE(message_state_timestamps.delivered_at, excluded.delivered_at),
        read_at = COALESCE(message_state_timestamps.read_at, excluded.read_at);
END;
CREATE TRIGGER record_updated_message_state_timestamps
AFTER UPDATE OF state ON messages
WHEN UPPER(NEW.state) IN ('SENT', 'DELIVERED', 'READ')
BEGIN
    INSERT INTO message_state_timestamps(message_id, sent_at, delivered_at, read_at)
    VALUES (NEW.id,
        CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER),
        CASE WHEN UPPER(NEW.state) IN ('DELIVERED', 'READ') THEN CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER) END,
        CASE WHEN UPPER(NEW.state) = 'READ' THEN CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER) END)
    ON CONFLICT(message_id) DO UPDATE SET
        sent_at = COALESCE(message_state_timestamps.sent_at, excluded.sent_at),
        delivered_at = COALESCE(message_state_timestamps.delivered_at, excluded.delivered_at),
        read_at = COALESCE(message_state_timestamps.read_at, excluded.read_at);
END;
CREATE VIEW messages_with_state_timestamps AS
SELECT messages.*, message_state_timestamps.sent_at,
       message_state_timestamps.delivered_at, message_state_timestamps.read_at
FROM messages LEFT JOIN message_state_timestamps
  ON message_state_timestamps.message_id = messages.id;
