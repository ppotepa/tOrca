SELECT MIN(ack_deadline) AS ack_deadline
                 FROM messages
                 WHERE outgoing = 1
                   AND UPPER(state) = 'SENT'
                   AND ack_deadline IS NOT NULL;
