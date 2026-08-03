INSERT INTO pairing_codes (code_hash, installation_id, expires_at)
VALUES ($1, $2, to_timestamp($3::double precision));
