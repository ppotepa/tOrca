INSERT INTO messages (
                id, conversation_id, outgoing, body, state, created_at,
                attempt_count, next_attempt_at
             ) VALUES ('history-message', 'conversation-history', 0, 'secret history', 'DELIVERED', 1, 0, 0);
