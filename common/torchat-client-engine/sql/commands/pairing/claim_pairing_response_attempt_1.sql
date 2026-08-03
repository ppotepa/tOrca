UPDATE pairing_inbox
                 SET attempt_count = attempt_count + 1,
                     next_attempt_at = ?1,
                     last_error = ?2,
                     updated_at = unixepoch()
                 WHERE pairing_id = ?3
                   AND expires_at >= ?4
                   AND response_delivered = 0
                   AND UPPER(state) IN ('ACCEPTED', 'REJECTED')
                   AND next_attempt_at <= ?5;
