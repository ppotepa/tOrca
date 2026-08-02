CREATE TABLE IF NOT EXISTS peer_endpoint_capabilities (
    contact_installation_id TEXT PRIMARY KEY,
    capability_id TEXT NOT NULL,
    secret_hash BLOB NOT NULL,
    secret_ciphertext BLOB NOT NULL,
    sequence INTEGER NOT NULL DEFAULT 1,
    issued_at INTEGER NOT NULL,
    expires_at INTEGER,
    revoked_at INTEGER,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (contact_installation_id) REFERENCES contacts(installation_id)
        ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_peer_endpoint_capabilities_id
    ON peer_endpoint_capabilities(capability_id);
