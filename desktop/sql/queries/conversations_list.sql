SELECT
    id,
    contact_installation_id,
    status,
    last_message_preview,
    last_message_at,
    unread_count
FROM conversations
ORDER BY
    last_message_at DESC,
    updated_at DESC,
    id;
