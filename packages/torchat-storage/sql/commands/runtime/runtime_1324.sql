UPDATE delivery_receipts
                 SET next_attempt_at = 0
                 WHERE state IN ('PENDING', 'SENT');
