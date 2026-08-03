INSERT INTO messages (
                id, conversation_id, outgoing, body, state, created_at,
                attempt_count, next_attempt_at
             ) VALUES (?1, ?2, 0, ?3, 'DELIVERED', 1, 0, 0);
