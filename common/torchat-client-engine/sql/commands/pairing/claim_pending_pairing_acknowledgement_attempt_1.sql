UPDATE pending_pairing_acknowledgements
                 SET attempt_count = attempt_count + 1,
                     next_attempt_at = ?1,
                     last_error = ?2
                 WHERE pairing_id = ?3
                   AND next_attempt_at <= ?4;
