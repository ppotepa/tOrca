UPDATE pending_welcomes
                 SET dead_lettered_at = NULL, next_attempt_at = 0
                 WHERE invite_id = ?1 AND dead_lettered_at IS NOT NULL;
