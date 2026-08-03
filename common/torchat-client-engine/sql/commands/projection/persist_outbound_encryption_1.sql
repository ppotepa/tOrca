UPDATE messages
                 SET relay_payload = ?2, ciphertext_hash = ?3
                 WHERE id = ?1;
