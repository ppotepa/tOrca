SELECT contact_installation_id, payload, endpoint_sequence, received_at
                 FROM pending_peer_endpoint_inbox
                 WHERE contact_installation_id = ?1;
