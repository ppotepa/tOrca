INSERT INTO conversations (
                id, contact_installation_id, state, unread_count,
                last_message_preview, last_message_at
             ) VALUES (?1, ?2, 'ACTIVE', 0, NULL, NULL);
