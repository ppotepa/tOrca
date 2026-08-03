UPDATE outbound_deliveries
                 SET state = 'QUEUED', next_attempt_at = ?1, ack_deadline = NULL,
                     claimed_until = NULL,
                     updated_at = unixepoch()
                 WHERE UPPER(state) = 'IN_FLIGHT';
