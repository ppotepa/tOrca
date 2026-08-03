SELECT installation_id
FROM installations
WHERE LOWER(TRIM(COALESCE(nickname, ''))) = LOWER(TRIM($1))
ORDER BY updated_at DESC, installation_id ASC
LIMIT 1;
