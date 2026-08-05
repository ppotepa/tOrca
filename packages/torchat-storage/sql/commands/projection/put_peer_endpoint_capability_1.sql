INSERT INTO peer_endpoint_capabilities (
                    contact_installation_id, capability_id, secret_hash,
                    secret_ciphertext, sequence, issued_at, expires_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, unixepoch())
                 ON CONFLICT(contact_installation_id) DO UPDATE SET
                    capability_id = excluded.capability_id,
                    secret_hash = excluded.secret_hash,
                    secret_ciphertext = excluded.secret_ciphertext,
                    sequence = excluded.sequence,
                    issued_at = excluded.issued_at,
                    expires_at = excluded.expires_at,
                    revoked_at = NULL,
                    updated_at = unixepoch()
                 WHERE excluded.sequence >= peer_endpoint_capabilities.sequence;
