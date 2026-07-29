CREATE TABLE IF NOT EXISTS contacts (
    owner_installation_id TEXT NOT NULL REFERENCES installations(installation_id) ON DELETE CASCADE,
    contact_installation_id TEXT NOT NULL REFERENCES installations(installation_id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (owner_installation_id, contact_installation_id),
    CHECK (owner_installation_id <> contact_installation_id)
);

CREATE INDEX IF NOT EXISTS contacts_owner_created_idx
    ON contacts(owner_installation_id, created_at DESC);
