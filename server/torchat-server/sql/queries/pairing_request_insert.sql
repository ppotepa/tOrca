INSERT INTO pending_pairings
    (pairing_id, sender_installation_id, recipient_installation_id, capability, expires_at)
VALUES ($1, $2, $3, $4, to_timestamp($5))
