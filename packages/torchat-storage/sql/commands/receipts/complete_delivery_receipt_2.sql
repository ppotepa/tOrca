UPDATE received_envelopes
                 SET receipt_state = 'DELIVERED'
                 WHERE message_id = ?1;
