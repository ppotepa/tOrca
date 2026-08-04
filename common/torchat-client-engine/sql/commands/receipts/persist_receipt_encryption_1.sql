UPDATE delivery_receipts
                 SET wire_ciphertext = COALESCE(wire_ciphertext, ?1),
                     state = 'SENT',
                     attempt_count = attempt_count + 1,
                     next_attempt_at = ?2,
                     last_error = ?3
                 WHERE message_id = ?4
                   AND UPPER(state) IN ('PENDING', 'SENT')
                   AND next_attempt_at <= ?5;
