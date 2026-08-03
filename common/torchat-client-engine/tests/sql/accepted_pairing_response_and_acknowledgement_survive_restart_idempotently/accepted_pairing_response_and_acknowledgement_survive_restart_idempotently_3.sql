SELECT attempt_count, next_attempt_at, last_error
                 FROM pending_pairing_acknowledgements
                 WHERE pairing_id = ?1;
