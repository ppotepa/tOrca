INSERT INTO local_peer_endpoint (
                    singleton, bundle_json, sequence, generation, updated_at
                 ) VALUES (1, ?1, ?2, ?3, unixepoch())
                 ON CONFLICT(singleton) DO UPDATE SET
                    bundle_json = excluded.bundle_json,
                    sequence = excluded.sequence,
                    generation = excluded.generation,
                    updated_at = unixepoch();
