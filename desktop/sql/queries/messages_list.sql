SELECT id, peer, outgoing, body, state, created_at, relay_payload,
       attempt_count, last_attempt_at, next_attempt_at, ack_deadline, last_transport_error
FROM messages
WHERE peer = ?1
ORDER BY created_at;
