PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS contacts (
    installation_id TEXT PRIMARY KEY,
    public_key TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    nickname TEXT NOT NULL,
    source TEXT NOT NULL,
    verification TEXT NOT NULL DEFAULT 'UNVERIFIED'
);

CREATE TABLE IF NOT EXISTS conversations (
    peer TEXT PRIMARY KEY,
    mls_state BLOB NOT NULL,
    unread_count INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    peer TEXT NOT NULL,
    outgoing INTEGER NOT NULL,
    body BLOB NOT NULL,
    state TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    relay_payload BLOB
);

CREATE INDEX IF NOT EXISTS messages_peer_time ON messages(peer, created_at);

CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value BLOB NOT NULL
);

CREATE TABLE IF NOT EXISTS used_invites (
    invite_id TEXT PRIMARY KEY,
    used_at INTEGER NOT NULL
);
