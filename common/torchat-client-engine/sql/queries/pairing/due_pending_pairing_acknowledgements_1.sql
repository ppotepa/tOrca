SELECT pairing_id, attempt_count
                 FROM pending_pairing_acknowledgements
                 WHERE next_attempt_at <= ?1
                 ORDER BY next_attempt_at ASC, pairing_id ASC;
