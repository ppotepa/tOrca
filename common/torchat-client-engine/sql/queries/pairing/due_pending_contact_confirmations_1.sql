SELECT pairing_id, peer_installation_id, capability, attempt_count,
                        next_attempt_at, last_error
                 FROM pending_contact_confirmations
                 WHERE next_attempt_at <= ?1
                 ORDER BY next_attempt_at ASC, pairing_id ASC;
