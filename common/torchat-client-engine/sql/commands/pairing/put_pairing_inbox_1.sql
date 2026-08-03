INSERT INTO pairing_inbox (
                    pairing_id, sender_installation_id, sender_nickname,
                    sender_public_key, sender_fingerprint, capability,
                    expires_at, state, offer_invite_id, offer_payload,
                    attempt_count, next_attempt_at, last_error, created_at, updated_at
                 ) VALUES (
                    ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 0, 0, NULL, unixepoch(), unixepoch()
                 )
                 ON CONFLICT(pairing_id) DO UPDATE SET
                    sender_installation_id = excluded.sender_installation_id,
                    sender_nickname = excluded.sender_nickname,
                    sender_public_key = excluded.sender_public_key,
                    sender_fingerprint = excluded.sender_fingerprint,
                    capability = excluded.capability,
                    expires_at = excluded.expires_at,
                    state = excluded.state,
                    offer_invite_id = excluded.offer_invite_id,
                    offer_payload = excluded.offer_payload,
                    attempt_count = CASE
                        WHEN pairing_inbox.state <> excluded.state
                          OR COALESCE(pairing_inbox.offer_invite_id, '') <> COALESCE(excluded.offer_invite_id, '')
                          OR COALESCE(pairing_inbox.offer_payload, X'') <> COALESCE(excluded.offer_payload, X'')
                        THEN 0
                        ELSE pairing_inbox.attempt_count
                    END,
                    next_attempt_at = CASE
                        WHEN pairing_inbox.state <> excluded.state
                          OR COALESCE(pairing_inbox.offer_invite_id, '') <> COALESCE(excluded.offer_invite_id, '')
                          OR COALESCE(pairing_inbox.offer_payload, X'') <> COALESCE(excluded.offer_payload, X'')
                        THEN 0
                        ELSE pairing_inbox.next_attempt_at
                    END,
                    last_error = CASE
                        WHEN pairing_inbox.state <> excluded.state
                          OR COALESCE(pairing_inbox.offer_invite_id, '') <> COALESCE(excluded.offer_invite_id, '')
                          OR COALESCE(pairing_inbox.offer_payload, X'') <> COALESCE(excluded.offer_payload, X'')
                        THEN NULL
                        ELSE pairing_inbox.last_error
                    END,
                    updated_at = unixepoch();
