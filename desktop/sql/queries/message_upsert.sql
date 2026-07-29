INSERT OR REPLACE INTO messages
    (id, peer, outgoing, body, state, created_at, relay_payload,
     attempt_count, last_attempt_at, next_attempt_at, ack_deadline, last_transport_error)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12);
