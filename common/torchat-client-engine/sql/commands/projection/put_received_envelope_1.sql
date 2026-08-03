INSERT INTO received_envelopes (
                    sender_installation_id, message_id, ciphertext_hash, received_at, receipt_state
                 ) VALUES (?1, ?2, ?3, ?4, ?5);
