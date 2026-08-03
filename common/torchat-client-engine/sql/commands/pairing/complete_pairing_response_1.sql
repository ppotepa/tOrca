UPDATE pairing_inbox
                 SET response_delivered = 1,
                     next_attempt_at = 0,
                     last_error = NULL,
                     updated_at = unixepoch()
                 WHERE pairing_id = ?1;
