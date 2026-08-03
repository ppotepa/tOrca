UPDATE relationship_removal_ack_outbox
                 SET state = 'ACKED', updated_at = unixepoch()
                 WHERE removal_id = ?1 AND state <> 'ACKED';
