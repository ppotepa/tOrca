SELECT installation_id
FROM pairing_codes
WHERE code_hash = $1 AND expires_at >= NOW()
LIMIT 1
