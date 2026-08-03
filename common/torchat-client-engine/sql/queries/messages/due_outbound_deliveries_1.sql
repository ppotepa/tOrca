SELECT message_id, contact_installation_id, sequence, state,
                        attempt_count, next_attempt_at, ack_deadline, last_error, created_at
                 FROM outbound_deliveries
                 WHERE UPPER(state) IN ('QUEUED', 'IN_FLIGHT')
                   AND next_attempt_at <= ?1
                 ORDER BY created_at ASC, message_id ASC
                 LIMIT ?2;
