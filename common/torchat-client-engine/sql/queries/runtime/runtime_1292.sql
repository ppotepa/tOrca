SELECT envelope_id, message_id, conversation_id, original_sender, received_at
                 FROM delivery_receipts
                 WHERE state IN ('PENDING', 'SENT')
                   AND next_attempt_at <= CAST(unixepoch('now') * 1000 AS INTEGER)
                 ORDER BY next_attempt_at ASC, created_at ASC, envelope_id ASC;
