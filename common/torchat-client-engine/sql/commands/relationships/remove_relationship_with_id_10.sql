DELETE FROM conversation_mls WHERE conversation_id IN (SELECT id FROM conversations WHERE contact_installation_id = ?1);
