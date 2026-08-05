UPDATE pairing_inbox
                 SET last_error = ?1,
                     updated_at = unixepoch()
                 WHERE pairing_id = ?2;
