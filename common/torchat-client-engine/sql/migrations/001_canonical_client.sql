CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value BLOB NOT NULL
);

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

CREATE TABLE IF NOT EXISTS conversation_mls (
    conversation_id TEXT PRIMARY KEY,
    snapshot BLOB NOT NULL,
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (conversation_id)
        REFERENCES conversations(id)
        ON DELETE CASCADE
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

CREATE TABLE IF NOT EXISTS pairing_inbox (
    pairing_id TEXT PRIMARY KEY,
    sender_installation_id TEXT NOT NULL,
    sender_nickname TEXT NOT NULL,
    sender_public_key TEXT NOT NULL,
    sender_fingerprint TEXT NOT NULL,
    capability TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    state TEXT NOT NULL,
    offer_invite_id TEXT,
    offer_payload BLOB,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS pairing_outbox (
    pairing_id TEXT PRIMARY KEY,
    recipient_installation_id TEXT,
    capability TEXT,
    payload BLOB,
    expires_at INTEGER NOT NULL,
    state TEXT NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS pending_welcomes (
    invite_id TEXT PRIMARY KEY,
    recipient_installation_id TEXT NOT NULL,
    payload BLOB NOT NULL,
    expires_at INTEGER NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    last_error TEXT
);

CREATE TABLE IF NOT EXISTS used_invites (
    invite_id TEXT PRIMARY KEY,
    used_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS received_envelopes (
    sender_installation_id TEXT NOT NULL,
    message_id TEXT NOT NULL,
    ciphertext_hash BLOB NOT NULL,
    received_at INTEGER NOT NULL,
    receipt_state TEXT NOT NULL,
    PRIMARY KEY (sender_installation_id, message_id)
);

CREATE TABLE IF NOT EXISTS delivery_receipts (
    envelope_id TEXT PRIMARY KEY,
    message_id TEXT NOT NULL UNIQUE,
    conversation_id TEXT NOT NULL,
    original_sender TEXT NOT NULL,
    received_at INTEGER NOT NULL,
    relay_payload BLOB,
    state TEXT NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at INTEGER NOT NULL
);
