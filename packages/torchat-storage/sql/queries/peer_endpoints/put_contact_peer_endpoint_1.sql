SELECT EXISTS(
                    SELECT 1 FROM relationship_tombstones
                    WHERE contact_installation_id = ?1
                );
