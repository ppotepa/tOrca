SELECT id, conversation_id, sender_id, body, state
FROM messages
WHERE id = ?1;
