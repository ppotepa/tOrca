INSERT INTO pending_pairings
    (pairing_id, sender_installation_id, recipient_installation_id, capability, expires_at)
VALUES ($1, $2, $3, $4, to_timestamp($5::double precision))
ON CONFLICT (sender_installation_id, recipient_installation_id) DO UPDATE
SET pairing_id = EXCLUDED.pairing_id,
    capability = EXCLUDED.capability,
    expires_at = EXCLUDED.expires_at,
    created_at = NOW()
WHERE pending_pairings.expires_at < NOW()
