SELECT
    id,
    contact_installation_id,
    status,
    last_message_preview,
    last_message_at,
    unread_count
FROM conversations
WHERE id = ?1;
