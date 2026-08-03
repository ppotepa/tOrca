SELECT MIN(next_attempt_at)
                 FROM outbound_deliveries
                 WHERE contact_installation_id = ?1
                   AND UPPER(state) = 'QUEUED';
