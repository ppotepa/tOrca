INSERT INTO connection_leases
    (installation_id, instance_id, connection_id, expires_at)
VALUES ($1, $2, $3, $4)
ON CONFLICT (installation_id) DO UPDATE
SET instance_id = EXCLUDED.instance_id,
    connection_id = EXCLUDED.connection_id,
    expires_at = EXCLUDED.expires_at,
    updated_at = NOW()
WHERE connection_leases.expires_at <= $5
   OR connection_leases.instance_id = $2
   OR connection_leases.connection_id = $3;
