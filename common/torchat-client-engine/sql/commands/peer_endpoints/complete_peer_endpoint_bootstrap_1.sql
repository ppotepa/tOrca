DELETE FROM peer_endpoint_bootstrap_outbox
                 WHERE contact_installation_id = ?1
                   AND endpoint_sequence <= ?2;
