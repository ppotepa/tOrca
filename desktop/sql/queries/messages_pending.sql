SELECT id, peer, outgoing, body, state, created_at, relay_payload
FROM messages
WHERE outgoing = 1 AND state IN ('pending', 'sending')
ORDER BY created_at;
