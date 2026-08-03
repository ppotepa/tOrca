UPDATE capability_delivery_outbox
                 SET attempt_count = attempt_count + 1,
                     next_attempt_at = ?1,
                     last_error = ?2
                 WHERE delivery_id = ?3 AND next_attempt_at <= ?4;
