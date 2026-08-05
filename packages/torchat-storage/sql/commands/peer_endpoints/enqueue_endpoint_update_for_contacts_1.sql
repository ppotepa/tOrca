INSERT OR IGNORE INTO endpoint_update_outbox (
                    contact_installation_id, payload, sequence, attempt_count,
                    next_attempt_at, last_error, updated_at
                 )
                 SELECT installation_id, ?1, ?2, 0, 0, NULL, unixepoch()
                 FROM contacts;
