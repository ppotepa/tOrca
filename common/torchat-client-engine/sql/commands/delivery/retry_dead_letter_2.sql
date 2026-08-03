UPDATE peer_endpoint_bootstrap_outbox
                 SET dead_lettered_at = NULL, next_attempt_at = 0
                 WHERE contact_installation_id = ?1 AND dead_lettered_at IS NOT NULL;
