UPDATE messages
                 SET next_attempt_at = 0
                 WHERE state IN ('QUEUED', 'SENDING');
