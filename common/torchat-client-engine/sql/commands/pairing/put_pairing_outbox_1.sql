INSERT INTO pairing_outbox (
                    pairing_id, recipient_installation_id, capability, payload,
                    expires_at, state, attempt_count, next_attempt_at, last_error,
                    created_at, updated_at
                 ) VALUES (
                    ?1, ?2, ?3, ?4, ?5, ?6, 0, 0, NULL, unixepoch(), unixepoch()
                 )
                 ON CONFLICT(pairing_id) DO UPDATE SET
                    recipient_installation_id = excluded.recipient_installation_id,
                    capability = excluded.capability,
                    payload = excluded.payload,
                    expires_at = excluded.expires_at,
                    state = excluded.state,
                    updated_at = unixepoch();
