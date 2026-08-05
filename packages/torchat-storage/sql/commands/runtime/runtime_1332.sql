UPDATE pairing_outbox
                 SET next_attempt_at = 0
                 WHERE state IN ('PENDING', 'ACCEPTED');
