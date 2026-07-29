SELECT pairing_id, expires_at, state
FROM pairing_outbox
ORDER BY expires_at ASC;
