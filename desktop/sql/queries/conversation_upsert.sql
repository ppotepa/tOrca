INSERT OR REPLACE INTO conversations
    (peer, mls_state, unread_count, updated_at)
VALUES (?1, ?2, ?3, unixepoch('subsec') * 1000);
