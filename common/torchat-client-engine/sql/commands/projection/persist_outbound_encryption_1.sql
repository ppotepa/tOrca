UPDATE messages
                 SET wire_ciphertext = ?2, ciphertext_hash = ?3
                 WHERE id = ?1;
