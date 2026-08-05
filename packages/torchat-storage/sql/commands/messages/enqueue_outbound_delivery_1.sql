INSERT INTO outbound_deliveries (
                    message_id, contact_installation_id, sequence, state,
                    attempt_count, next_attempt_at, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, 'QUEUED', 0, 0, ?4, unixepoch())
                 ON CONFLICT(message_id) DO NOTHING;
