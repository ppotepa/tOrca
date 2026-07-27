SELECT id, peer, outgoing, body, state, created_at, relay_payload
FROM messages
WHERE peer = ?1
ORDER BY created_at;
