CREATE TABLE IF NOT EXISTS connection_leases (
    installation_id TEXT PRIMARY KEY,
    instance_id UUID NOT NULL,
    connection_id UUID NOT NULL,
    expires_at BIGINT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS connection_leases_expiry_idx ON connection_leases (expires_at);
