INSERT OR REPLACE INTO delivery_receipts (
                    envelope_id, message_id, conversation_id, original_sender, received_at,
                    wire_ciphertext, state, attempt_count, next_attempt_at, last_error, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);
