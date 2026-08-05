SELECT EXISTS(
                    SELECT 1
                    FROM conversations c
                    JOIN relationship_tombstones t
                      ON t.contact_installation_id = c.contact_installation_id
                    WHERE c.id = ?1
                );
