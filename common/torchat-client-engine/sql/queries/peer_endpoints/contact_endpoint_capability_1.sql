SELECT capability_id, secret_ciphertext, sequence, revoked_at, expires_at
                 FROM contact_endpoint_capabilities
                 WHERE contact_installation_id = ?1;
