SELECT EXISTS(
                    SELECT 1 FROM capability_delivery_outbox
                    WHERE contact_installation_id = ?1
                 );
