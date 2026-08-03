UPDATE messages
                 SET state = CASE
                         WHEN UPPER(state) = 'SENDING' THEN 'QUEUED'
                         ELSE state
                     END,
                     next_attempt_at = 0,
                     ack_deadline = NULL
                 WHERE conversation_id = ?1
                   AND outgoing = 1
                   AND UPPER(state) IN ('QUEUED', 'SENDING');
