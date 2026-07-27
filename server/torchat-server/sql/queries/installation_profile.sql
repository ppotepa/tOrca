SELECT public_key, nickname
FROM installations
WHERE installation_id = $1 AND revoked_at IS NULL
