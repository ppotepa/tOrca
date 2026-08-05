INSERT INTO messages (
                id, conversation_id, outgoing, body, state, created_at,
                wire_ciphertext, attempt_count, next_attempt_at
             ) VALUES (?1, ?2, 1, ?3, 'QUEUED', ?4, ?5, 0, 0);
