WITH candidate AS (
    SELECT route_id
    FROM connection_route_stream
    WHERE installation_id = $1
      AND expires_at > $2
      AND (claimed_until IS NULL OR claimed_until <= $2)
    ORDER BY created_at, route_id
    FOR UPDATE SKIP LOCKED
    LIMIT 1
)
UPDATE connection_route_stream route
SET claimed_by = $3, claimed_until = $4
FROM candidate
WHERE route.route_id = candidate.route_id
RETURNING route.route_id, route.payload;
