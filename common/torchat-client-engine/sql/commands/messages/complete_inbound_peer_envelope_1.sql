UPDATE inbound_peer_envelopes
                 SET state = 'DELIVERED', updated_at = unixepoch()
                 WHERE sender_installation_id = ?1 AND message_id = ?2;
