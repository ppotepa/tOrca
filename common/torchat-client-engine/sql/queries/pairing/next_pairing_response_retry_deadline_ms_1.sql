SELECT MIN(next_attempt_at) AS next_attempt_at
                 FROM pairing_inbox
                 WHERE expires_at >= ?1
                   AND response_delivered = 0
                   AND UPPER(state) IN ('ACCEPTED', 'REJECTED');
