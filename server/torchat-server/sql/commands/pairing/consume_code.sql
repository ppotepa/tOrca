DELETE FROM pairing_codes
WHERE code_hash = $1 AND expires_at >= NOW()
RETURNING installation_id;
