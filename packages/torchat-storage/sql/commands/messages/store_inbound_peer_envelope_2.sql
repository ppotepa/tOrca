INSERT INTO inbound_peer_envelopes (
                    sender_installation_id, message_id, conversation_id, sequence,
                    ciphertext, ciphertext_hash, state, received_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'PERSISTED', ?7, unixepoch());
