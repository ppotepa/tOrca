SELECT pairing_id
FROM pending_pairings
WHERE sender_installation_id = $1
  AND recipient_installation_id = $2
LIMIT 1
