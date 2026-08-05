INSERT INTO relationship_removal_outbox
                (removal_id, contact_installation_id, relationship_epoch, preserve_history, state, next_attempt_at)
             VALUES (?1, ?2, ?3, ?4, 'PENDING', 0)
             ON CONFLICT(removal_id) DO UPDATE SET updated_at = unixepoch();
