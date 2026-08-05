UPDATE messages SET state = 'FAILED', next_attempt_at = 0, ack_deadline = NULL, last_transport_error = 'relationship removed'
             WHERE conversation_id IN (SELECT id FROM conversations WHERE contact_installation_id = ?1)
             AND outgoing = 1 AND UPPER(state) IN ('QUEUED', 'SENDING');
