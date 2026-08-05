SELECT ciphertext_hash, state
                 FROM inbound_peer_envelopes
                 WHERE sender_installation_id = ?1 AND message_id = ?2;
