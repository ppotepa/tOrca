INSERT INTO pending_welcomes (
                invite_id, recipient_installation_id, payload, expires_at,
                attempt_count, next_attempt_at
             ) VALUES (?1, ?2, ?3, ?4, 4, ?5);
