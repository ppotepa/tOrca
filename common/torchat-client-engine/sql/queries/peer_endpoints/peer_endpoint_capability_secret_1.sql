SELECT secret_ciphertext FROM peer_endpoint_capabilities
                 WHERE contact_installation_id = ?1
                   AND capability_id = ?2
                   AND revoked_at IS NULL
                   AND (expires_at IS NULL OR expires_at >= unixepoch());
