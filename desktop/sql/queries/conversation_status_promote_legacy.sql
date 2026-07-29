UPDATE conversations
SET
    status = 'ACTIVE',
    updated_at = unixepoch('subsec') * 1000
WHERE id = ?1
  AND status = 'PENDING';
