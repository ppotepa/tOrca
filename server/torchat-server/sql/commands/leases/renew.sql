UPDATE connection_leases
SET expires_at = $4, updated_at = NOW()
WHERE installation_id = $1 AND instance_id = $2 AND connection_id = $3;
