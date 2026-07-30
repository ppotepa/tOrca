CREATE TABLE pending_peer_endpoint_inbox (
    contact_installation_id TEXT PRIMARY KEY NOT NULL,
    payload BLOB NOT NULL,
    endpoint_sequence INTEGER NOT NULL,
    received_at INTEGER NOT NULL
);

CREATE INDEX idx_pending_peer_endpoint_inbox_received
    ON pending_peer_endpoint_inbox(received_at);
