CREATE TABLE received_envelopes (
    sender_installation_id TEXT NOT NULL,
    message_id TEXT NOT NULL,
    ciphertext_hash BLOB NOT NULL,
    received_at INTEGER NOT NULL,
    receipt_state TEXT NOT NULL,
    PRIMARY KEY (
        sender_installation_id,
        message_id
    )
);

CREATE INDEX received_envelopes_receipt_pending
ON received_envelopes (
    receipt_state,
    received_at
);
