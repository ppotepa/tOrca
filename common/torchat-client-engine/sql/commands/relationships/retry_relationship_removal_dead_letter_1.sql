UPDATE relationship_removal_outbox
                 SET state = 'PENDING', next_attempt_at = 0, updated_at = unixepoch()
                 WHERE removal_id = ?1 AND state = 'DEAD_LETTER';
