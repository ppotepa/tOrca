INSERT INTO pending_peer_endpoint_inbox (
                    contact_installation_id, payload, endpoint_sequence, received_at
                 ) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(contact_installation_id) DO UPDATE SET
                    payload = excluded.payload,
                    endpoint_sequence = excluded.endpoint_sequence,
                    received_at = excluded.received_at
                 WHERE excluded.endpoint_sequence > pending_peer_endpoint_inbox.endpoint_sequence;
