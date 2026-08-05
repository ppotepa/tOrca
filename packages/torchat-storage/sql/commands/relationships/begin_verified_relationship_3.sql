INSERT INTO relationship_boundaries
                    (contact_installation_id, boundary_at, relationship_epoch)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(contact_installation_id) DO UPDATE SET
                    boundary_at = excluded.boundary_at,
                    relationship_epoch = MAX(relationship_boundaries.relationship_epoch,
                                             excluded.relationship_epoch);
