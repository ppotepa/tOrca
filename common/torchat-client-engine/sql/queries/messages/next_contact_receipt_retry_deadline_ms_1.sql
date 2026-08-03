SELECT MIN(next_attempt_at)
                 FROM delivery_receipts
                 WHERE original_sender = ?1
                   AND UPPER(state) = 'PENDING';
