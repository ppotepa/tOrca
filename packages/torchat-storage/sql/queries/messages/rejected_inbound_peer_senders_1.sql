SELECT DISTINCT sender_installation_id
                 FROM inbound_peer_envelopes
                 WHERE UPPER(state) = 'REJECTED';
