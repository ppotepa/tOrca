SELECT invite_id, recipient_installation_id, payload, expires_at,
                        attempt_count, next_attempt_at, last_error
                 FROM pending_welcomes
                 WHERE expires_at >= ?1
                 ORDER BY expires_at ASC, invite_id ASC;
