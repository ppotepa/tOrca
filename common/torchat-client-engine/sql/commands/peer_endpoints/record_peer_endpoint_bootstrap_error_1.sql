UPDATE peer_endpoint_bootstrap_outbox
                 SET last_error = ?1,
                     dead_lettered_at = CASE WHEN ?1 LIKE 'permanent:%' OR ?1 LIKE 'protocol:%' THEN unixepoch() ELSE dead_lettered_at END,
                     updated_at = unixepoch()
                 WHERE contact_installation_id = ?2
                   AND endpoint_sequence = ?3;
