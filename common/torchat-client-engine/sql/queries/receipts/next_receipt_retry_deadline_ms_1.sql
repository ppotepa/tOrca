SELECT MIN(next_attempt_at) AS next_attempt_at
                 FROM delivery_receipts
                 WHERE UPPER(state) IN ('PENDING', 'SENT');
