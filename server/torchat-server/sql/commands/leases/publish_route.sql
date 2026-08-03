INSERT INTO connection_route_stream
    (route_id, installation_id, instance_id, connection_id,
     payload, created_at, expires_at)
VALUES ($1, $2, $3, $4, $5, $6, $7)
ON CONFLICT (route_id) DO NOTHING;
