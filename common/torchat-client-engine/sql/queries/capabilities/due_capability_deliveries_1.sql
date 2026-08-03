SELECT delivery_id, contact_installation_id, payload,
                        attempt_count, next_attempt_at, last_error, created_at
                 FROM capability_delivery_outbox
                 WHERE next_attempt_at <= ?1 AND dead_lettered_at IS NULL
                 ORDER BY next_attempt_at ASC, created_at ASC;
