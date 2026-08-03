UPDATE relationship_removal_ack_outbox
             SET state = CASE WHEN attempt_count + 1 >= ?3 THEN 'DEAD_LETTER' ELSE 'DISPATCHED' END,
                 attempt_count = attempt_count + 1,
                 next_attempt_at = ?2, updated_at = unixepoch()
             WHERE removal_id = ?1 AND state IN ('PENDING', 'DISPATCHED');
