INSERT INTO pending_pairing_acknowledgements (
                    pairing_id, attempt_count, next_attempt_at, last_error
                 ) VALUES (?1, 0, 0, ?2)
                 ON CONFLICT(pairing_id) DO UPDATE SET
                    next_attempt_at = 0,
                    last_error = excluded.last_error;
