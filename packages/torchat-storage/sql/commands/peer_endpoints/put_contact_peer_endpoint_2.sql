INSERT INTO contact_peer_endpoints (
                    contact_installation_id, bundle_json, sequence, updated_at
                 ) VALUES (?1, ?2, ?3, unixepoch())
                 ON CONFLICT(contact_installation_id) DO UPDATE SET
                    bundle_json = excluded.bundle_json,
                    sequence = excluded.sequence,
                    updated_at = unixepoch()
                 WHERE excluded.sequence > contact_peer_endpoints.sequence;
