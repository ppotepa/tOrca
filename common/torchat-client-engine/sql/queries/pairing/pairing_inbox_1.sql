SELECT pairing_id, sender_installation_id, sender_nickname,
                        sender_public_key, sender_fingerprint, capability,
                        expires_at, state, offer_invite_id, offer_payload
                 FROM pairing_inbox
                 ORDER BY updated_at DESC, pairing_id ASC;
