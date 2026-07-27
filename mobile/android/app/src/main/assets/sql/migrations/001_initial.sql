CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    outgoing INTEGER NOT NULL,
    body TEXT,
    ciphertext BLOB NOT NULL,
    state TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    remote_message_id TEXT,
    error TEXT
);

CREATE TABLE IF NOT EXISTS contacts (
    installation_id TEXT PRIMARY KEY,
    nickname TEXT NOT NULL,
    public_key TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    key_package BLOB,
    verification TEXT NOT NULL,
    source TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    contact_installation_id TEXT NOT NULL UNIQUE,
    mls_state BLOB,
    status TEXT NOT NULL,
    unread_count INTEGER NOT NULL,
    last_message_preview TEXT,
    last_message_at INTEGER
);

CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value BLOB NOT NULL
);

CREATE TABLE IF NOT EXISTS used_invites (
    invite_id TEXT PRIMARY KEY,
    used_at INTEGER NOT NULL
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
    offer_payload BLOB
);
