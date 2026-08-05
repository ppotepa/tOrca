SELECT id, conversation_id, outgoing, body, reply_to_json, state, created_at,
                                attempt_count, last_attempt_at, next_attempt_at,
                                ack_deadline, last_transport_error
                         FROM messages
                         WHERE conversation_id = ?1
                         ORDER BY created_at ASC, id ASC;
