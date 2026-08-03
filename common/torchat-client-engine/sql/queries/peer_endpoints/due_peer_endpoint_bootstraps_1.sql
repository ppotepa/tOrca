SELECT contact_installation_id, payload, endpoint_sequence, attempt_count,
                        next_attempt_at, last_error
                 FROM peer_endpoint_bootstrap_outbox
                 WHERE next_attempt_at <= ?1 AND dead_lettered_at IS NULL
                 ORDER BY next_attempt_at ASC, contact_installation_id ASC;
