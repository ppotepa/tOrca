UPDATE received_envelopes
                 SET receipt_state = 'PENDING'
                 WHERE message_id = ?1;
