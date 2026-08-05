SELECT invite_id, recipient_installation_id, payload, expires_at,
                        attempt_count, next_attempt_at, last_error
                 FROM pending_welcomes
                 WHERE next_attempt_at <= ?1
                   AND expires_at >= ?2
                   AND dead_lettered_at IS NULL
                 ORDER BY next_attempt_at ASC, invite_id ASC;
