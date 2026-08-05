INSERT INTO contact_endpoint_capabilities (
                    contact_installation_id, capability_id, secret_hash, secret_ciphertext,
                    issued_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, unixepoch(), unixepoch())
                 ON CONFLICT(contact_installation_id) DO UPDATE SET
                    capability_id = excluded.capability_id,
                    secret_hash = excluded.secret_hash,
                    secret_ciphertext = excluded.secret_ciphertext,
                    sequence = contact_endpoint_capabilities.sequence + 1,
                    issued_at = unixepoch(),
                    revoked_at = NULL,
                    updated_at = unixepoch();
