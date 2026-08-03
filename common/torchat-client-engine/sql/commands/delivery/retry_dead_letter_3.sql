UPDATE pending_contact_confirmations
                 SET dead_lettered_at = NULL, next_attempt_at = 0
                 WHERE pairing_id = ?1 AND dead_lettered_at IS NOT NULL;
