UPDATE relationship_removal_outbox
                 SET state = 'ACKED', updated_at = unixepoch()
                 WHERE removal_id = ?1;
