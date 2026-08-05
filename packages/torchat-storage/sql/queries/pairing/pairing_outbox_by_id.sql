SELECT pairing_id, pair_key, recipient_installation_id, capability,
       payload, expires_at, state
FROM pairing_outbox
WHERE pairing_id = ?1
LIMIT 1;
