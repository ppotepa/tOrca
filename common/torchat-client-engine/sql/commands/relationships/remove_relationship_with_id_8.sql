DELETE FROM delivery_receipts WHERE conversation_id IN
             (SELECT id FROM conversations WHERE contact_installation_id = ?1);
