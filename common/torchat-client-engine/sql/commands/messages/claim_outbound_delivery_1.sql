UPDATE outbound_deliveries
                 SET state = 'IN_FLIGHT',
                     attempt_count = attempt_count + 1,
                     next_attempt_at = ?2,
                     ack_deadline = ?3,
                     last_error = NULL,
                     updated_at = unixepoch()
                 WHERE message_id = ?1
                   AND (
                       UPPER(state) = 'QUEUED'
                       OR (
                           UPPER(state) = 'IN_FLIGHT'
                           AND COALESCE(ack_deadline, 0) <= ?4
                       )
                   );
