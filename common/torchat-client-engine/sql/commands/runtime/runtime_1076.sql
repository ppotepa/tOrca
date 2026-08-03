UPDATE conversations
                 SET unread_count = 0, updated_at = unixepoch()
                 WHERE id = ?1;
