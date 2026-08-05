SELECT next_attempt_at, last_error
             FROM pending_welcomes
             WHERE invite_id = ?1;
