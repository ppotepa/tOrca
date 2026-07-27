SELECT installation_id
FROM sessions
WHERE token_hash = $1
  AND revoked_at IS NULL
  AND expires_at > NOW()
