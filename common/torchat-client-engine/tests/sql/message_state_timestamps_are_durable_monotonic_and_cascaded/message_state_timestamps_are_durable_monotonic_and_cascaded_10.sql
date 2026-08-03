SELECT state, sent_at, delivered_at, read_at
                 FROM messages_with_state_timestamps
                 WHERE id = ?1;
