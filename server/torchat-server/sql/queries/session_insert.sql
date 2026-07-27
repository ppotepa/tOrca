INSERT INTO sessions (token_hash, installation_id, expires_at)
VALUES ($1, $2, NOW() + INTERVAL '24 hours')
