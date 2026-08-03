INSERT INTO pending_contact_confirmations (
                    pairing_id, peer_installation_id, capability, attempt_count,
                    next_attempt_at, last_error, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, 0, 0, NULL, unixepoch(), unixepoch())
                 ON CONFLICT(pairing_id) DO UPDATE SET
                    peer_installation_id = excluded.peer_installation_id,
                    capability = excluded.capability,
                    attempt_count = 0,
                    next_attempt_at = 0,
                    last_error = NULL,
                    updated_at = unixepoch();
