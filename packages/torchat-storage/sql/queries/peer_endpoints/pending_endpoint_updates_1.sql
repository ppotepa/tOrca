SELECT payload
                 FROM endpoint_update_outbox
                 WHERE contact_installation_id = ?1
                 ORDER BY sequence ASC;
