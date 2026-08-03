UPDATE messages
SET dead_lettered_at = unixepoch(), last_error_code = ?1
WHERE id = ?2;
