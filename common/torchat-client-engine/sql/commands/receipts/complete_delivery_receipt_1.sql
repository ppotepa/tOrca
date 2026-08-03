UPDATE delivery_receipts
                 SET state = 'DELIVERED', next_attempt_at = 0, last_error = NULL
                 WHERE message_id = ?1;
