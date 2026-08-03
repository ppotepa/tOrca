SELECT instance_id, connection_id, expires_at
FROM connection_leases
WHERE installation_id = $1 AND expires_at > $2;
