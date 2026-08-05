UPDATE contact_peer_endpoints
                 SET last_connected_at = ?2, updated_at = unixepoch()
                 WHERE contact_installation_id = ?1;
