SELECT id, conversation_id, outgoing, body, reply_to_json, state, created_at,
                        attempt_count, last_attempt_at, next_attempt_at,
                        ack_deadline, last_transport_error
                 FROM messages
                 WHERE state IN ('QUEUED', 'SENDING')
                   AND next_attempt_at <= CAST(unixepoch('now') * 1000 AS INTEGER)
                 ORDER BY next_attempt_at ASC, created_at ASC, id ASC;
