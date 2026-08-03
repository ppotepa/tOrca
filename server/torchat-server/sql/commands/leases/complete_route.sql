DELETE FROM connection_route_stream
WHERE route_id = $1 AND claimed_by = $2;
