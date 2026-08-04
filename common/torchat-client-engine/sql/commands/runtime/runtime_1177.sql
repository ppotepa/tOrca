INSERT INTO messages (
                    id, conversation_id, outgoing, body, reply_to_json, state, created_at,
                    wire_ciphertext, ciphertext_hash, attempt_count, last_attempt_at,
                    next_attempt_at, ack_deadline, last_transport_error
                 ) VALUES (
                    ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14
                 )
                 ON CONFLICT(id) DO UPDATE SET
                    conversation_id = excluded.conversation_id,
                    outgoing = excluded.outgoing,
                    body = excluded.body,
                    reply_to_json = excluded.reply_to_json,
                    state = excluded.state,
                    created_at = excluded.created_at,
                    attempt_count = excluded.attempt_count,
                    last_attempt_at = excluded.last_attempt_at,
                    next_attempt_at = excluded.next_attempt_at,
                    ack_deadline = excluded.ack_deadline,
                    last_transport_error = excluded.last_transport_error;
