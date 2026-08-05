SELECT sender_installation_id, message_id, conversation_id, sequence,
                        ciphertext, ciphertext_hash, state, received_at
                 FROM inbound_peer_envelopes
                 WHERE UPPER(state) = 'PERSISTED'
                 ORDER BY received_at ASC, message_id ASC;
