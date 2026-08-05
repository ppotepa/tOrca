SELECT sent_at, delivered_at, read_at
                 FROM message_state_timestamps
                 WHERE message_id = ?1;
