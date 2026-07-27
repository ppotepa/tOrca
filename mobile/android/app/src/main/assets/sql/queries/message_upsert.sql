INSERT OR REPLACE INTO messages
    (id, conversation_id, outgoing, body, ciphertext, state, created_at, remote_message_id, error)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
