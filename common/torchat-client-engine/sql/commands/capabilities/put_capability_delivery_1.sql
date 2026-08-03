INSERT INTO capability_delivery_outbox (
                    delivery_id, contact_installation_id, payload,
                    attempt_count, next_attempt_at, last_error, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(delivery_id) DO UPDATE SET
                    payload = excluded.payload,
                    attempt_count = excluded.attempt_count,
                    next_attempt_at = excluded.next_attempt_at,
                    last_error = excluded.last_error;
