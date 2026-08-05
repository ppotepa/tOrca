UPDATE delivery_receipts
                 SET state = 'PENDING', next_attempt_at = ?1
                 WHERE UPPER(state) = 'SENT';
