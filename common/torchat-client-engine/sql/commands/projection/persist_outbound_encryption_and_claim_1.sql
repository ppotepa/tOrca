UPDATE messages
                 SET wire_ciphertext = ?2,
                     ciphertext_hash = ?3,
                     attempt_count = attempt_count + 1,
                     last_attempt_at = ?4,
                     next_attempt_at = ?5,
                     ack_deadline = ?6,
                     last_transport_error = NULL
                 WHERE id = ?1
                   AND outgoing = 1
                   AND UPPER(state) IN ('SENDING', 'QUEUED')
                   AND next_attempt_at <= ?4;
