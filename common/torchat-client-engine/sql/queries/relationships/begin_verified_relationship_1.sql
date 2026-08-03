SELECT MAX(
                    COALESCE((SELECT relationship_epoch
                              FROM relationship_boundaries
                              WHERE contact_installation_id = ?1), 0),
                    COALESCE((SELECT relationship_epoch
                              FROM relationship_tombstones
                              WHERE contact_installation_id = ?1), 0)
                );
