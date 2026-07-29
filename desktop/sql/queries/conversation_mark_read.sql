UPDATE conversations
SET
    unread_count = 0,
    updated_at = unixepoch('subsec') * 1000
WHERE id = ?1;
