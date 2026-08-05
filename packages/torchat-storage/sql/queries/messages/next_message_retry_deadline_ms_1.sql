SELECT MIN(next_attempt_at) AS next_attempt_at
                 FROM messages
                 WHERE outgoing = 1
                   AND UPPER(state) IN ('SENDING', 'QUEUED');
