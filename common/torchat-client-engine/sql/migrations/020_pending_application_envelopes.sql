-- MLS ciphertext is already encrypted end-to-end. The envelope metadata is
-- retained only until the local Welcome transaction creates the conversation.
CREATE TABLE pending_application_envelopes (
    sender_installation_id TEXT NOT NULL,
    message_id TEXT NOT NULL,
    envelope_json TEXT NOT NULL,
    ciphertext BLOB NOT NULL,
    ciphertext_hash BLOB NOT NULL,
    received_at INTEGER NOT NULL,
    PRIMARY KEY (sender_installation_id, message_id)
);

CREATE INDEX idx_pending_application_envelopes_received
    ON pending_application_envelopes(received_at);
