INSERT INTO relationship_tombstones (contact_installation_id, removed_at, preserve_history, relationship_epoch, removal_id)
             VALUES (?1, ?2, 1, ?3, ?4)
             ON CONFLICT(contact_installation_id) DO UPDATE SET
               removed_at = MAX(relationship_tombstones.removed_at, excluded.removed_at),
               preserve_history = 1,
               relationship_epoch = MAX(relationship_tombstones.relationship_epoch, excluded.relationship_epoch),
               removal_id = CASE WHEN excluded.relationship_epoch >= relationship_tombstones.relationship_epoch THEN excluded.removal_id ELSE relationship_tombstones.removal_id END;
