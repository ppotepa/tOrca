CREATE TABLE IF NOT EXISTS contact_endpoint_capabilities (
    contact_installation_id TEXT PRIMARY KEY,
    capability_id TEXT NOT NULL UNIQUE,
    secret_hash BLOB NOT NULL,
    secret_ciphertext BLOB NOT NULL,
    sequence INTEGER NOT NULL DEFAULT 1,
    issued_at INTEGER NOT NULL,
    expires_at INTEGER,
    revoked_at INTEGER,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (contact_installation_id)
        REFERENCES contacts(installation_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_contact_endpoint_capabilities_active
ON contact_endpoint_capabilities(revoked_at, expires_at, contact_installation_id);
