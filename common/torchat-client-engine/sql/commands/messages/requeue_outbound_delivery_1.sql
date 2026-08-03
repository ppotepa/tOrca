UPDATE outbound_deliveries
                 SET state = 'QUEUED', next_attempt_at = ?2, ack_deadline = NULL,
                     last_error = ?3, updated_at = unixepoch()
                 WHERE message_id = ?1;
