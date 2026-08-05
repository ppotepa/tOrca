SELECT id, contact_installation_id, state,
       COALESCE(last_message_preview, '') AS last_message_preview,
       COALESCE(last_message_at, 0) AS last_message_at,
       unread_count
FROM conversations
WHERE contact_installation_id = ?1
ORDER BY COALESCE(last_message_at, 0) DESC, id ASC
LIMIT 1;
