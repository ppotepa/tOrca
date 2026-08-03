DELETE FROM connection_leases
WHERE installation_id = $1 AND instance_id = $2 AND connection_id = $3;
