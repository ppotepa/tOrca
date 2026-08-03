CREATE TABLE IF NOT EXISTS installations (
    installation_id TEXT PRIMARY KEY,
    public_key TEXT NOT NULL,
    nickname TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at TIMESTAMPTZ
);
ALTER TABLE installations ADD COLUMN IF NOT EXISTS nickname TEXT;
CREATE INDEX IF NOT EXISTS installations_nickname_idx ON installations (nickname);
CREATE TABLE IF NOT EXISTS sessions (
    token_hash TEXT PRIMARY KEY,
    installation_id TEXT NOT NULL REFERENCES installations(installation_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS sessions_installation_idx ON sessions (installation_id);
DROP TABLE IF EXISTS envelopes;
