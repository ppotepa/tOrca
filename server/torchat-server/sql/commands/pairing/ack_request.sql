DELETE FROM pending_pairings
WHERE pairing_id = $1 AND recipient_installation_id = $2;
