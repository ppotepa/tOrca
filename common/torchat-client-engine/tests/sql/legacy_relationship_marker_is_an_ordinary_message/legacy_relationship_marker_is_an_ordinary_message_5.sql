INSERT INTO messages (
                id, conversation_id, outgoing, body, state, created_at,
                attempt_count, next_attempt_at
             ) VALUES (?1, ?2, 1, ?3, 'QUEUED', 2, 0, 0);
