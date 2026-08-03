UPDATE peer_endpoint_bootstrap_outbox
                 SET attempt_count = attempt_count + 1,
                     next_attempt_at = ?1,
                     last_error = ?2,
                     updated_at = unixepoch()
                 WHERE contact_installation_id = ?3
                   AND endpoint_sequence = ?4
                   AND next_attempt_at <= ?5;
