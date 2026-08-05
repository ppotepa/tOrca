SELECT sender_installation_id, message_id, envelope_json,
                        ciphertext, ciphertext_hash, received_at
                 FROM pending_application_envelopes
                 WHERE sender_installation_id = ?1
                 ORDER BY received_at ASC, message_id ASC;
