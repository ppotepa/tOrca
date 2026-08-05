UPDATE outbound_deliveries
                 SET state = 'QUEUED', next_attempt_at = 0, ack_deadline = NULL,
                     updated_at = unixepoch()
                 WHERE contact_installation_id = ?1;
