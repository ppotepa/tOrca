INSERT INTO peer_endpoint_bootstrap_outbox (
                    contact_installation_id, payload, endpoint_sequence, attempt_count,
                    next_attempt_at, last_error, updated_at
                 ) VALUES (?1, ?2, ?3, 0, 0, NULL, unixepoch())
                 ON CONFLICT(contact_installation_id) DO UPDATE SET
                    payload = excluded.payload,
                    endpoint_sequence = excluded.endpoint_sequence,
                    attempt_count = 0,
                    next_attempt_at = 0,
                    last_error = NULL,
                    updated_at = unixepoch()
                 WHERE excluded.endpoint_sequence >= peer_endpoint_bootstrap_outbox.endpoint_sequence;
