CREATE TABLE IF NOT EXISTS connection_route_stream (
    route_id UUID PRIMARY KEY,
    installation_id TEXT NOT NULL,
    instance_id UUID NOT NULL,
    connection_id UUID NOT NULL,
    payload BYTEA NOT NULL,
    created_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    claimed_by UUID,
    claimed_until BIGINT
);

CREATE INDEX IF NOT EXISTS connection_route_stream_due_idx
    ON connection_route_stream (installation_id, expires_at, created_at);
