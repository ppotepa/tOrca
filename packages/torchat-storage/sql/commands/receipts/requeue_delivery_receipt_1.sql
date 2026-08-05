UPDATE delivery_receipts
                 SET state = 'PENDING', next_attempt_at = ?1, last_error = ?2
                 WHERE message_id = ?3;
