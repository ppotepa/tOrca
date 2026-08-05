SELECT id, conversation_id, outgoing, body, state, created_at,
                        wire_ciphertext,
                        ciphertext_hash, attempt_count, last_attempt_at,
                        next_attempt_at, ack_deadline, last_transport_error
                 FROM messages
                 WHERE id = ?1;
