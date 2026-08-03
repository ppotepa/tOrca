SELECT relay_payload, ciphertext_hash
                 FROM messages
                 WHERE id = ?1;
