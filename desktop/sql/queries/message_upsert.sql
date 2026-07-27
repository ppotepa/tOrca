INSERT OR REPLACE INTO messages
    (id, peer, outgoing, body, state, created_at, relay_payload)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);
