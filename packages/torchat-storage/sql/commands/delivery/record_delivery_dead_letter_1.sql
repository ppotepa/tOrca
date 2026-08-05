INSERT INTO delivery_dead_letters
                 (kind, item_id, contact_installation_id, attempt_count, last_error, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, unixepoch(), unixepoch())
                 ON CONFLICT(kind, item_id) DO UPDATE SET
                    contact_installation_id = excluded.contact_installation_id,
                    attempt_count = excluded.attempt_count,
                    last_error = excluded.last_error,
                    updated_at = unixepoch();
