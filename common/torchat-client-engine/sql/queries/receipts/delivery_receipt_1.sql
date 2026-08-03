SELECT envelope_id, message_id, conversation_id, original_sender, received_at,
                        relay_payload, state, attempt_count, next_attempt_at, last_error, created_at
                 FROM delivery_receipts
                 WHERE message_id = ?1;
