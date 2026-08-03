INSERT INTO pairing_inbox (
                    pairing_id, sender_installation_id, sender_nickname,
                    sender_public_key, sender_fingerprint, capability,
                    expires_at, state, offer_invite_id, offer_payload,
                    attempt_count, next_attempt_at, last_error,
                    response_delivered
                 ) VALUES (
                    ?1, ?2, ?3, ?4, ?5, ?6,
                    ?7, 'ACCEPTED', ?8, ?9,
                    0, 0, NULL, 0
                 );
