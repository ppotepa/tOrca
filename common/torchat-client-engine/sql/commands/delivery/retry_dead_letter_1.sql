UPDATE capability_delivery_outbox
                 SET dead_lettered_at = NULL, next_attempt_at = 0
                 WHERE delivery_id = ?1 AND dead_lettered_at IS NOT NULL;
