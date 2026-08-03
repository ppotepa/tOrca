UPDATE contact_endpoint_capabilities
                 SET revoked_at = unixepoch(), updated_at = unixepoch()
                 WHERE contact_installation_id = ?1;
