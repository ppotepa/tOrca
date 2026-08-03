UPDATE received_envelopes
                 SET receipt_state = 'SENT'
                 WHERE message_id = ?1;
