SELECT sender_installation_id, message_id, ciphertext_hash, received_at, receipt_state
                 FROM received_envelopes
                 WHERE sender_installation_id = ?1 AND message_id = ?2;
