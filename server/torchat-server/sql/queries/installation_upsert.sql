INSERT INTO installations (installation_id, public_key)
VALUES ($1, $2)
ON CONFLICT (installation_id) DO UPDATE SET public_key = EXCLUDED.public_key
