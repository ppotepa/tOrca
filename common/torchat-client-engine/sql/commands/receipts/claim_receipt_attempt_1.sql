UPDATE delivery_receipts
                 SET state = 'SENT',
                     attempt_count = attempt_count + 1,
                     next_attempt_at = ?1,
                     last_error = ?2
                 WHERE message_id = ?3
                   AND UPPER(state) IN ('PENDING', 'SENT')
                   AND next_attempt_at <= ?4;
