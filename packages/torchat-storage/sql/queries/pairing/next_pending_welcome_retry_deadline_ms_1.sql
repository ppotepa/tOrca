SELECT MIN(next_attempt_at) AS next_attempt_at
                 FROM pending_welcomes
                 WHERE expires_at >= ?1;
