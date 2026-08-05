UPDATE messages
                 SET state = 'QUEUED',
                     next_attempt_at = ?1,
                     ack_deadline = NULL,
                     claimed_until = NULL
                 WHERE outgoing = 1
                   AND UPPER(state) = 'SENDING'
                   AND id IN (
                        SELECT message_id
                        FROM outbound_deliveries
                        WHERE UPPER(state) = 'QUEUED'
                   );
