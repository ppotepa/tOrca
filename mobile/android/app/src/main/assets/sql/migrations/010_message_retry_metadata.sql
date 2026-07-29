ALTER TABLE messages
    ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0;

ALTER TABLE messages
    ADD COLUMN last_attempt_at INTEGER;

ALTER TABLE messages
    ADD COLUMN next_attempt_at INTEGER NOT NULL DEFAULT 0;

ALTER TABLE messages
    ADD COLUMN ack_deadline INTEGER;

ALTER TABLE messages
    ADD COLUMN last_transport_error TEXT;

CREATE INDEX messages_retry_due
ON messages (
    outgoing,
    state,
    next_attempt_at,
    created_at
);
