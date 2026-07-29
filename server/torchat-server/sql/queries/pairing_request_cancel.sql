DELETE FROM pending_pairings
WHERE pairing_id = $1 AND sender_installation_id = $2;
