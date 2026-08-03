DROP TABLE IF EXISTS contact_requests;
CREATE TABLE IF NOT EXISTS pairing_codes (
    code_hash TEXT PRIMARY KEY,
    installation_id TEXT NOT NULL REFERENCES installations(installation_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS pairing_codes_one_active_per_installation ON pairing_codes(installation_id);
CREATE TABLE IF NOT EXISTS pending_pairings (
    pairing_id UUID PRIMARY KEY,
    sender_installation_id TEXT NOT NULL REFERENCES installations(installation_id),
    recipient_installation_id TEXT NOT NULL REFERENCES installations(installation_id),
    capability TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    CHECK (sender_installation_id <> recipient_installation_id)
);
CREATE INDEX IF NOT EXISTS pending_pairings_recipient_idx ON pending_pairings(recipient_installation_id, created_at);
