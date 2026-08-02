SELECT pairing_id, EXTRACT(EPOCH FROM expires_at)::BIGINT
FROM pending_pairings
WHERE sender_installation_id = $1
  AND recipient_installation_id = $2
  AND expires_at >= NOW()
LIMIT 1
