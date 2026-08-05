INSERT INTO messages (
                    id, conversation_id, outgoing, body, state, created_at,
                    attempt_count, next_attempt_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
