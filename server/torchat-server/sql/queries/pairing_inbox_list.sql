SELECT pairing_id, sender_installation_id, capability,
       EXTRACT(EPOCH FROM expires_at)::BIGINT
FROM pending_pairings
WHERE recipient_installation_id = $1 AND expires_at >= NOW()
ORDER BY created_at ASC
