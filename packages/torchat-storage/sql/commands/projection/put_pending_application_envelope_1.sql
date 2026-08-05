INSERT INTO pending_application_envelopes (
                    sender_installation_id, message_id, envelope_json,
                    ciphertext, ciphertext_hash, received_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(sender_installation_id, message_id) DO UPDATE SET
                    envelope_json = excluded.envelope_json,
                    ciphertext = excluded.ciphertext,
                    ciphertext_hash = excluded.ciphertext_hash,
                    received_at = excluded.received_at;
