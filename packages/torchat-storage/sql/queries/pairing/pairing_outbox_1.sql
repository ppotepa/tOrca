SELECT pairing_id, pair_key, recipient_installation_id, capability, payload,
                        expires_at, state
                 FROM pairing_outbox
                 ORDER BY updated_at DESC, pairing_id ASC;
