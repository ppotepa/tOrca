SELECT id
                 FROM messages
                 WHERE outgoing = 1
                   AND UPPER(state) = 'SENT'
                   AND ack_deadline IS NOT NULL
                   AND ack_deadline <= ?1
                 ORDER BY ack_deadline ASC, created_at ASC, id ASC;
