INSERT OR REPLACE INTO messages
    (
        id,
        conversation_id,
        outgoing,
        body,
        ciphertext,
        state,
        created_at,
        remote_message_id,
        error,
        attempt_count,
        last_attempt_at,
        next_attempt_at,
        ack_deadline,
        last_transport_error
    )
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
